// ============================================================================
// verify-phone-code — 전화 인증번호 검증
//   POST { phone: string, code: string, purpose?: 'signup' | 'password_reset' }
//   같은 phone+purpose 의 미사용·미만료 최신 code 일치 확인 → is_used=true.
//   verify_jwt=false: 로그인 전 단계. service_role 로만 DB 접근.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { normalizePhone } from "../_shared/solapi.ts";

const PURPOSES = new Set(["signup", "password_reset"]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let payload: { phone?: string; code?: string; purpose?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const phone = normalizePhone(payload.phone ?? "");
  const code = (payload.code ?? "").trim();
  const purpose = payload.purpose ?? "signup";
  if (!/^01\d{8,9}$/.test(phone)) return json({ error: "invalid_phone" }, 400);
  if (!/^\d{6}$/.test(code)) return json({ error: "invalid_code" }, 400);
  if (!PURPOSES.has(purpose)) return json({ error: "invalid_purpose" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 미사용·미만료 최신 코드 1건 조회
  const { data, error } = await supabase
    .from("phone_verifications")
    .select("id, code")
    .eq("phone", phone)
    .eq("purpose", purpose)
    .eq("is_used", false)
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error("verify query failed", error);
    return json({ error: "internal_error" }, 500);
  }
  if (!data || data.code !== code) {
    return json({ verified: false, error: "code_mismatch_or_expired" }, 400);
  }

  // 일치 → 사용 처리(재사용 방지)
  const { error: updErr } = await supabase
    .from("phone_verifications")
    .update({ is_used: true })
    .eq("id", data.id);
  if (updErr) {
    console.error("mark used failed", updErr);
    return json({ error: "internal_error" }, 500);
  }

  return json({ verified: true });
});
