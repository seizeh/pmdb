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
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  ACCESS_TTL_CAPABLE, bearer, clientUa, randomToken, sha256Hex, signAccess, verifyAccess,
} from "../_shared/auth.ts";
import { hashPassword, verifyPassword } from "../_shared/passwords.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);

  const tok = bearer(req);
  const claims = tok ? await verifyAccess(tok, secret) : null;
  const uid = claims?.sub as string | undefined;
  if (!uid) return json({ error: "unauthorized" }, 401);
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
  if (next.length < 6) return json({ error: "weak_password" }, 400); // 구 app._set_password 정책 유지

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
});
