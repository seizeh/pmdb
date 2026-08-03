// ============================================================================
// verify-phone-code — 전화 인증번호 검증
//   POST { phone: string, code: string, purpose?: 'signup' | 'password_reset' | 'review' }
//   같은 phone+purpose 의 미사용·미만료 최신 code 일치 확인 → is_used=true.
//   verify_jwt=false: 로그인 전 단계. service_role 로만 DB 접근.
//   ⚠ purpose='review'(간이 후기)는 보통 이 함수를 거치지 않는다 — signup-lite 가
//   검증·계정생성·토큰발급을 한 번에 한다(코드 소지와 세션 발급을 분리하면
//   남의 인증을 가로챌 창이 생긴다). 여기 목록에 둔 건 재사용 여지를 위해서다.
//
//   ── 시도 제한이 왜 필요했나 ────────────────────────────────────────────
//   종전에는 대입 횟수에 아무 제한이 없었다. 틀린 코드는 is_used 를 바꾸지도,
//   카운터를 올리지도 않아서 **같은 코드에 몇 번이든 찍어 볼 수 있었다**.
//   6자리는 100만 조합이고 코드 수명은 5분이지만, 60초마다 새 코드를 받아 가며
//   병렬로 돌리면 확률은 시간이 해결해 준다. 그리고 그 경로의 끝이 나쁘다:
//     send-phone-code(purpose='password_reset') → 여기서 대입 → reset-password
//   즉 계정 인수까지 이어진다. 실패한 대입은 아무 로그도 남기지 않으므로
//   관리자 화면에도, 실사용 관찰에도 흔적이 없다.
//
//   버킷은 signup-lite 와 같은 모양으로 둔다(전화번호 1차 + IP 보조). 전화번호는
//   대입 대상 그 자체라 스푸핑할 수 없고, IP 는 보조선이다(clientIp 주석 참고).
//   실패한 대입만 세는 게 아니라 호출 자체를 세는데, 성공하면 어차피 코드가
//   소진돼 재호출할 이유가 없으므로 정상 사용자에게는 차이가 없다.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { clientIp, rateLimited } from "../_shared/auth.ts";
import { normalizePhone } from "../_shared/solapi.ts";

const PURPOSES = new Set(["signup", "password_reset", "review"]);

// 대입 제한 — signup-lite(lite:phone 10/600, lite:ip 30/600)와 같은 값.
// 10분당 10회면 100만 조합을 반쯤 훑는 데만 1년 가까이 걸린다. 반대쪽으로는
// 오타 몇 번에 막히지 않을 만큼 넉넉하다(코드 재발송은 60초당 1회).
const ATTEMPT_MAX_PHONE = 10;
const ATTEMPT_MAX_IP = 30;
const ATTEMPT_WINDOW_SEC = 600;

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

  // 대입 제한 — 코드 조회 **전에** 소모한다(제한에 걸린 요청이 DB 를 읽지 않게).
  const ip = clientIp(req);
  if (
    await rateLimited(
      supabase,
      `otpverify:phone:${phone}:${purpose}`,
      ATTEMPT_MAX_PHONE,
      ATTEMPT_WINDOW_SEC,
    ) ||
    (ip !== null &&
      await rateLimited(
        supabase,
        `otpverify:ip:${ip}`,
        ATTEMPT_MAX_IP,
        ATTEMPT_WINDOW_SEC,
      ))
  ) {
    return json({ error: "rate_limited" }, 429);
  }

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
