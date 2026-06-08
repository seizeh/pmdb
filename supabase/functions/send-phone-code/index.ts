// ============================================================================
// send-phone-code — 전화 인증번호(6자리·5분) 발급 + Solapi SMS 발송
//   POST { phone: string, purpose?: 'signup' | 'password_reset' }
//   흐름: rate limit(동일 번호 60초 1회) → 코드 생성 → phone_verifications INSERT
//         → Solapi 발송. service_role 로만 DB 접근(RLS 정책 없음).
//   verify_jwt=false: 가입/비번재설정은 로그인 전 단계라 JWT 없음. 남용은 자체 rate limit 으로 방어.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { loadSolapiConfig, normalizePhone, sendSms } from "../_shared/solapi.ts";

const CODE_TTL_MIN = 5;
const RATE_LIMIT_SEC = 60;
const PURPOSES = new Set(["signup", "password_reset"]);

function genCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let payload: { phone?: string; purpose?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const phone = normalizePhone(payload.phone ?? "");
  const purpose = payload.purpose ?? "signup";
  if (!/^01\d{8,9}$/.test(phone)) return json({ error: "invalid_phone" }, 400);
  if (!PURPOSES.has(purpose)) return json({ error: "invalid_purpose" }, 400);

  let cfg;
  try {
    cfg = loadSolapiConfig();
  } catch (e) {
    console.error(e);
    return json({ error: "server_misconfigured" }, 500);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 1) rate limit: 동일 번호+목적 최근 60초 내 발급 이력 차단
  const since = new Date(Date.now() - RATE_LIMIT_SEC * 1000).toISOString();
  const { count, error: rlErr } = await supabase
    .from("phone_verifications")
    .select("id", { count: "exact", head: true })
    .eq("phone", phone)
    .eq("purpose", purpose)
    .gte("created_at", since);
  if (rlErr) {
    console.error("rate-limit query failed", rlErr);
    return json({ error: "internal_error" }, 500);
  }
  if ((count ?? 0) > 0) {
    return json({ error: "rate_limited", retry_after_sec: RATE_LIMIT_SEC }, 429);
  }

  // 2) 코드 생성 + 저장(발송 직전 INSERT)
  const code = genCode();
  const expires_at = new Date(Date.now() + CODE_TTL_MIN * 60 * 1000).toISOString();
  const { error: insErr } = await supabase
    .from("phone_verifications")
    .insert({ phone, code, purpose, expires_at });
  if (insErr) {
    console.error("insert failed", insErr);
    return json({ error: "internal_error" }, 500);
  }

  // 3) Solapi 발송
  const text = `[PawMate] 인증번호 ${code} (5분 내 입력)`;
  const result = await sendSms(cfg, phone, text);
  if (!result.ok) {
    console.error("solapi send failed", result.status, result.body);
    return json({ error: "sms_send_failed", detail: result.body }, 502);
  }

  return json({ ok: true, expires_in_sec: CODE_TTL_MIN * 60 });
});
