// ============================================================================
// refresh — refresh 토큰 회전 → 새 access + refresh 쌍 발급
//   POST { refresh_token }
//   rt_rotate RPC(service_role)로 원자적 회전 + grace 유예(30s) 처리.
//     rotated|grace → 새 쌍 발급 / invalid|expired|inactive|reuse_revoked → 401.
//   verify_jwt=false: 만료된 access 를 갱신하는 단계이므로 access 검증 안 함.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  ACCESS_TTL_CAPABLE, clientUa, randomToken, REFRESH_GRACE_SECONDS, sha256Hex, signAccess,
} from "../_shared/auth.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);

  let p: { refresh_token?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const raw = (p.refresh_token ?? "").trim();
  if (!raw) return json({ error: "missing_refresh_token" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const newRaw = randomToken();
  const { data, error } = await supabase.rpc("rt_rotate", {
    p_old_hash: await sha256Hex(raw),
    p_new_hash: await sha256Hex(newRaw),
    p_user_agent: clientUa(req),
    p_grace_seconds: REFRESH_GRACE_SECONDS,
  });
  if (error) {
    console.error("rt_rotate failed", error);
    return json({ error: "internal_error" }, 500);
  }
  const row = (data as Array<{ result: string; user_id: string | null; token_version: number | null }>)?.[0];
  if (!row || (row.result !== "rotated" && row.result !== "grace")) {
    return json({ error: row?.result ?? "invalid" }, 401);
  }

  const token = await signAccess(row.user_id!, row.token_version ?? 0, ACCESS_TTL_CAPABLE, secret);
  return json({ ok: true, token, refresh_token: newRaw, expires_in: ACCESS_TTL_CAPABLE });
});
