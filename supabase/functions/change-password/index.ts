// ============================================================================
// change-password — 비밀번호 변경 + 전 세션 무효화 + 현재 기기 재발급 (원자적)
//   POST { current_password, new_password }   Authorization: Bearer <access JWT>
//   1) access JWT 수동 검증 → uid (+tv 클레임)
//   2) get_password_hash 로 현재 해시 조회 → 여기서 현재 비번 검증(argon2id/bcrypt)
//   3) change_password_and_rotate(uid, cur_hash(CAS), new_hash, tv, token_hash) —
//      단일 트랜잭션: 세션(status+tv) 검증 → 해시 CAS 갱신 → token_version bump +
//      refresh 전량 회수 → 현재 기기용 새 family 발급. 중간 실패 시 전체 롤백.
//      (CAS: 검증~갱신 사이 다른 세션이 비번을 바꿨으면 invalid_current 로 롤백)
//   verify_jwt=false: 커스텀 JWT 수동 검증(다른 함수와 동일 패턴).
//
// ⚠️ **이 함수만 activeUid 가 아니라 verifyAccess 인 이유** — status·token_version
//   게이트가 엣지가 아니라 change_password_and_rotate **트랜잭션 안**에 있다(위 3).
//   엣지에서 검사하면 검사~회전 사이 TOCTOU 창이 생기므로, 여기서는 하류의 원자
//   게이트가 정본이고 verifyAccess 는 uid·tv 추출용이다.
//   단 **lite 클레임은 DB 가 볼 수 없다**(사용자 status 가 아니라 토큰 클레임) —
//   그래서 아래에서 엣지가 직접 거른다. 이 검사가 빠져 있던 동안, 전화 OTP 만으로
//   발급되는 lite 토큰(계정의 실제 tv 로 서명됨) + 현재 비밀번호로 아이디 없이
//   전 세션 무효화 + 완전 세션 발급이 가능했다(2026-09-21 봉합, #154·#181 계열).
//   **새 인증 함수는 이 파일을 선례로 삼지 말 것 — activeUid 를 쓴다.**
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, withCors } from "../_shared/cors.ts";
import {
  ACCESS_TTL_CAPABLE, bearer, clientUa, randomToken, sha256Hex, signAccess, verifyAccess,
} from "../_shared/auth.ts";
import { hashPassword, verifyPassword } from "../_shared/passwords.ts";

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);

  const tok = bearer(req);
  const claims = tok ? await verifyAccess(tok, secret) : null;
  const uid = claims?.sub as string | undefined;
  if (!uid) return json({ error: "unauthorized" }, 401);
  // lite(간이 후기) 토큰 거부 — 헤더 주석 참조. activeUid 와 같은 텍스트 비교.
  if (String(claims?.lite ?? "") === "true") return json({ error: "unauthorized" }, 401);
  const tv = (claims?.tv as number | undefined) ?? 0;

  let p: { current_password?: string; new_password?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const cur = p.current_password ?? "";
  const next = p.new_password ?? "";
  if (!cur || !next) return json({ error: "missing_fields" }, 400);
  // 가입(signup)·재설정(reset-password)과 **같은 규칙**: 8자 이상 + 영문 + 숫자.
  // 종전에는 6자 길이만 봤다(구 app._set_password 정책이 남은 것) — 가입에서 막은
  // 단순 비밀번호를 '변경'으로 우회할 수 있는 구멍이었다.
  // 에러코드는 weak_password 유지 — 앱이 이미 매핑하고 있어 바꾸면 안내가 깨진다.
  // ⚠️ 앱 쪽 정본은 pmdart `lib/utils/password_rule.dart` — 규칙을 바꾸면 같이 고칠 것.
  if (next.length < 8 || !/[A-Za-z]/.test(next) || !/\d/.test(next)) {
    return json({ error: "weak_password" }, 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 현재 비번 검증 — 저장 해시를 가져와 여기서 확인(argon2id/bcrypt 겸용).
  const { data: curHash, error: hErr } = await supabase.rpc("get_password_hash", { p_user: uid });
  if (hErr) {
    console.error("get_password_hash failed", hErr);
    return json({ error: "internal_error" }, 500);
  }
  if (!curHash) return json({ error: "unauthorized" }, 401); // 미존재/비활성 계정
  if (!(await verifyPassword(cur, curHash as string))) {
    return json({ error: "invalid_current" }, 401);
  }

  // 현재 기기용 새 refresh 원문을 여기서 생성(해시만 RPC 로) → 원자적으로 발급.
  const refreshToken = randomToken();
  const { data: tvData, error } = await supabase.rpc("change_password_and_rotate", {
    p_user: uid,
    p_current_hash: curHash,
    p_new_hash: await hashPassword(next),
    p_tv: tv,
    p_new_token_hash: await sha256Hex(refreshToken),
    p_user_agent: clientUa(req),
  });
  if (error) {
    const m = error.message ?? "";
    if (m.includes("not_authenticated")) return json({ error: "unauthorized" }, 401); // tv 불일치/정지
    if (m.includes("invalid_current")) return json({ error: "invalid_current" }, 401);
    if (m.includes("weak_password")) return json({ error: "weak_password" }, 400);
    console.error("change_password_and_rotate failed", error);
    return json({ error: "internal_error" }, 500);
  }

  const newTv = (tvData as number | null) ?? 0;
  const token = await signAccess(uid, newTv, ACCESS_TTL_CAPABLE, secret);
  return json({ ok: true, token, refresh_token: refreshToken, expires_in: ACCESS_TTL_CAPABLE });
}));
