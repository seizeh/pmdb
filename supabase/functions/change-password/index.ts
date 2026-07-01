// ============================================================================
// change-password — 비밀번호 변경 + 전 세션 무효화 + 현재 기기 재발급
//   POST { current_password, new_password }   Authorization: Bearer <access JWT>
//   1) access JWT 수동 검증 → uid
//   2) change_password_svc(uid, cur, new) — 현재 비번 검증 + 갱신
//   3) bump_token_version(uid) — 모든 기존 access 즉시 무효(타 기기 즉사)
//   4) rt_revoke_user(uid) — 모든 refresh 회수 후, 현재 기기용 새 쌍 발급
//   verify_jwt=false: 커스텀 JWT 수동 검증(다른 함수와 동일 패턴).
//   ※ refresh 지원 클라(phase 2) 전용. 레거시 앱은 기존 change_password RPC 사용.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  ACCESS_TTL_CAPABLE, bearer, randomToken, sha256Hex, signAccess, verifyAccess,
} from "../_shared/auth.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);

  const tok = bearer(req);
  const claims = tok ? await verifyAccess(tok, secret) : null;
  const uid = claims?.sub as string | undefined;
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: { current_password?: string; new_password?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const cur = p.current_password ?? "";
  const next = p.new_password ?? "";
  if (!cur || !next) return json({ error: "missing_fields" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { error: cpErr } = await supabase.rpc("change_password_svc", {
    p_user: uid, p_current: cur, p_new: next,
  });
  if (cpErr) {
    const m = cpErr.message ?? "";
    if (m.includes("invalid_current")) return json({ error: "invalid_current" }, 401);
    if (m.includes("weak_password")) return json({ error: "weak_password" }, 400);
    console.error("change_password_svc failed", cpErr);
    return json({ error: "internal_error" }, 500);
  }

  // 전 세션 무효화: token_version bump(모든 access 즉시 무효) + 모든 refresh 회수.
  const { data: tvData, error: bumpErr } = await supabase.rpc("bump_token_version", { p_user: uid });
  if (bumpErr) {
    console.error("bump_token_version failed", bumpErr);
    return json({ error: "internal_error" }, 500);
  }
  const newTv = (tvData as number | null) ?? 0;
  await supabase.rpc("rt_revoke_user", { p_user: uid });

  // 현재 기기용 새 쌍 발급.
  const refreshToken = randomToken();
  const { error: rtErr } = await supabase.rpc("rt_issue", {
    p_user: uid,
    p_token_hash: await sha256Hex(refreshToken),
    p_user_agent: req.headers.get("user-agent") ?? null,
  });
  if (rtErr) {
    console.error("rt_issue failed", rtErr);
    return json({ error: "internal_error" }, 500);
  }

  const token = await signAccess(uid, newTv, ACCESS_TTL_CAPABLE, secret);
  return json({ ok: true, token, refresh_token: refreshToken, expires_in: ACCESS_TTL_CAPABLE });
});
