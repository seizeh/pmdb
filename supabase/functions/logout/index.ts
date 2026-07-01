// ============================================================================
// logout — refresh 토큰의 family 전체 회수(현재 기기 로그아웃). 멱등.
//   POST { refresh_token }
//   rt_revoke_family RPC(service_role). 항상 200(존재 여부 노출 안 함).
//   verify_jwt=false.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { sha256Hex } from "../_shared/auth.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let p: { refresh_token?: string };
  try {
    p = await req.json();
  } catch {
    return json({ ok: true }); // 잘못된 바디도 멱등 성공 취급
  }
  const raw = (p.refresh_token ?? "").trim();
  if (raw) {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { error } = await supabase.rpc("rt_revoke_family", { p_hash: await sha256Hex(raw) });
    if (error) console.error("rt_revoke_family failed", error);
  }
  return json({ ok: true });
});
