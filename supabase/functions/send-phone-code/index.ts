// ============================================================================
// send-phone-code — 전화 인증번호(6자리·5분) 발급 + Solapi SMS 발송
//   POST { phone: string, purpose?: 'signup' | 'password_reset' | 'review' }
//   흐름: 목적별 계정 존재 검증 → rate limit(동일 번호 60초 1회) → 코드 생성
//         → phone_verifications INSERT → Solapi 발송. service_role 로만 DB 접근.
//   가입: 이미 가입된 번호 차단(phone_taken) / 재설정: 미가입 번호 차단(user_not_found)
//   — 불필요한 SMS 발송·오용 방지(같은 정보는 어차피 최종 단계에서 노출되므로
//     계정 열거 위험이 새로 늘지 않음).
//   review(간이 후기, 0029): 계정 존재 여부를 **보지 않는다** — 정식 회원도 간이
//   경로로 후기를 쓸 수 있어야 하는데 signup 목적을 재사용하면 phone_taken 에
//   막힌다. 목적을 나눠야 후기용 인증이 가입에 전용되는 것도 함께 막힌다.
//   남용은 자체 rate limit 으로 방어(아래 세 층).
//
//   ── 왜 번호별 60초만으로는 부족했나 ────────────────────────────────────
//   종전 제한은 `phone+purpose 60초 1회` 하나뿐이었다. 그건 **한 사람이 재발송을
//   연타하는 것**을 막는 장치지, 발송 **총량**을 막는 장치가 아니다. 번호를
//   바꿔가며 부르면 상한이 없다 — 문자 한 통마다 실제 돈이 나가고, 우리 발신번호로
//   남의 폰에 문자가 꽂힌다. purpose='review' 는 계정 존재 검사도 하지 않으므로
//   (그게 설계 의도다) 가입 여부와 무관하게 **아무 번호로나** 보낼 수 있다.
//   게이트웨이의 verify_jwt 는 방어가 아니다 — publishable 키는 앱 번들에 실려
//   있고 저장소도 공개다.
//
//   드러나는 경로가 청구서뿐이라는 게 진짜 문제였다. 그래서 세 층으로 나눈다:
//     ① phone+purpose 60초 1회   기존. 개인의 재발송 연타(UX 쿨다운).
//     ② IP 시간당 20통           한 출처가 번호를 갈아타며 쏟아내는 것.
//     ③ 전역 시간당 200통        ②를 우회한 분산 시도까지 포함한 **비용 상한**.
//   ②는 우회 가능한 보조선이 **아니다.** `cf-connecting-ip` 는 위조하면 Cloudflare
//   엣지가 요청 자체를 거부하고 이 배포에서는 그 헤더가 항상 붙는다(clientIp 주석의
//   실측). 즉 한 출처의 발송량은 ②만으로도 실제로 묶이고, ③은 그 위에 얹는 총량
//   보험이지 ②의 대체물이 아니다. ③에 걸리면 정상 가입도 함께 막히므로 **관리자에게
//   즉시 알린다** — 조용히 막고 있으면 "가입이 안 돼요" 문의만 쌓이고 원인은 로그
//   안에 묻힌다.
//
//   데모 백도어(심사·테스트 서버용): DEMO_PHONES(콤마 구분)·DEMO_OTP(6자리) 시크릿이
//   둘 다 설정된 환경에서만, 해당 번호에 한해 SMS 발송 없이 고정 코드를 저장한다.
//   verify-phone-code 이후는 실번호와 완전히 동일한 경로. 미설정(운영 기본)이면 죽은 코드.
//   데모 번호는 문자를 보내지 않으므로 ②③ 어느 층도 소모하지 않는다.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { clientIp, rateLimited } from "../_shared/auth.ts";
import { alertAdmins } from "../_shared/edge_alert.ts";
import { loadSolapiConfig, normalizePhone, sendSms } from "../_shared/solapi.ts";

const CODE_TTL_MIN = 5;
const RATE_LIMIT_SEC = 60;
const PURPOSES = new Set(["signup", "password_reset", "review"]);

// ② 출처별 상한. 한 사람이 정상적으로 쓰는 양(가입 1통 + 재발송 몇 통)보다 훨씬
//    넉넉하되, 번호를 갈아타는 스크립트에는 즉시 걸린다. 사무실·통신사 NAT 로
//    IP 를 공유하는 경우를 감안해 시간당 20통.
const IP_MAX = 20;
const IP_WINDOW_SEC = 3600;

// ③ 전역 상한(비용 상한). 베타 실사용량과는 자릿수가 다르다 — 정상 운영 중에는
//    절대 닿지 않아야 하고, 닿았다면 그 자체가 사건이라 알림을 띄운다.
//    창이 1시간이라 잘못 걸려도 최대 1시간 뒤 스스로 풀린다(일 단위로 잡으면
//    하루치 가입이 통째로 막힌다).
const GLOBAL_MAX = 200;
const GLOBAL_WINDOW_SEC = 3600;

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

  // 데모 여부 판정 — 번호 목록과 6자리 고정 코드가 모두 유효할 때만 활성.
  const demoPhones = new Set(
    (Deno.env.get("DEMO_PHONES") ?? "").split(",").map((s) => normalizePhone(s)).filter(Boolean),
  );
  const demoOtp = Deno.env.get("DEMO_OTP") ?? "";
  const isDemo = demoPhones.has(phone) && /^\d{6}$/.test(demoOtp);

  // 데모 경로는 SMS 를 안 보내므로 Solapi 설정이 없어도 동작해야 한다.
  let cfg = null;
  if (!isDemo) {
    try {
      cfg = loadSolapiConfig();
    } catch (e) {
      console.error(e);
      return json({ error: "server_misconfigured" }, 500);
    }
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ②) 출처별 상한 — 계정 존재 검증보다 **앞에** 둔다. 뒤에 두면 phone_taken /
  //     user_not_found 응답으로 번호 가입 여부를 훑는 호출이 아무 대가 없이
  //     지나간다(그 열거 자체가 문자 발송의 앞단이다).
  const ip = isDemo ? null : clientIp(req);
  if (ip !== null && await rateLimited(supabase, `sms:ip:${ip}`, IP_MAX, IP_WINDOW_SEC)) {
    // 창이 1시간인 버킷이므로 60 을 돌려주면 안 된다 — 앱이 그 값을 그대로
    // "N초 후 재발송 가능" 으로 띄우기 때문에, 최대 1시간 막힌 사용자가 60초 뒤
    // 다시 눌러 또 막힌다. 재시도가 아무것도 해결하지 못하는 구간에서 재시도를
    // 권하는 문구가 되는 것이라, 이 PR 이 verify 쪽에서 고치려던 문제와 동종이다.
    return json({ error: "rate_limited", retry_after_sec: IP_WINDOW_SEC }, 429);
  }

  // 0) 목적별 계정 존재 검증 — 가입된 번호에 가입용 문자를 보내지 않는다.
  //    review 는 어느 분기에도 걸리지 않는다(존재 여부 무관 발송).
  const { data: existing, error: exErr } = await supabase
    .from("users").select("id").eq("phone", phone).limit(1).maybeSingle();
  if (exErr) {
    console.error("phone lookup failed", exErr);
    return json({ error: "internal_error" }, 500);
  }
  if (purpose === "signup" && existing) {
    return json({ error: "phone_taken" }, 409);
  }
  if (purpose === "password_reset" && !existing) {
    return json({ error: "user_not_found" }, 404);
  }

  // 1) rate limit: 동일 번호+목적 최근 60초 내 발급 이력 차단
  //    (데모 번호는 면제 — SMS 비용이 없고, 심사 중 재시도 마찰을 없앤다)
  if (!isDemo) {
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
  }

  // ③) 전역 상한 — 여기서부터는 실제로 문자가 나간다. 발송 직전에 소모해
  //     "세었는데 안 보냈다"(또는 그 반대)가 생기지 않게 한다.
  //     걸리면 정상 가입까지 막히므로 조용히 지나가서는 안 된다 — 관리자 알림은
  //     30분 스로틀이 걸려 있어(edge_alert) 폭주해도 알림이 폭주하지 않는다.
  if (!isDemo) {
    if (await rateLimited(supabase, "sms:global", GLOBAL_MAX, GLOBAL_WINDOW_SEC)) {
      console.error("global SMS cap reached", { purpose, ip });
      await alertAdmins(
        supabase,
        "sms-global-cap",
        "문자 발송 전역 상한 도달",
        `최근 ${GLOBAL_WINDOW_SEC / 60}분간 인증문자 ${GLOBAL_MAX}통을 넘겼습니다. ` +
          "정상 유입인지 남용인지 확인이 필요하고, 그동안 신규 가입·비밀번호 재설정이 막힙니다.",
      );
      return json({ error: "rate_limited", retry_after_sec: GLOBAL_WINDOW_SEC }, 429);
    }
  }

  // 2) 코드 생성 + 저장(발송 직전 INSERT) — 데모는 고정 코드
  const code = isDemo ? demoOtp : genCode();
  const expires_at = new Date(Date.now() + CODE_TTL_MIN * 60 * 1000).toISOString();
  const { error: insErr } = await supabase
    .from("phone_verifications")
    .insert({ phone, code, purpose, expires_at });
  if (insErr) {
    console.error("insert failed", insErr);
    return json({ error: "internal_error" }, 500);
  }

  // 3) Solapi 발송 — 데모 번호는 저장만 하고 발송 생략(응답 형태는 동일)
  if (isDemo) {
    console.log("demo verification issued:", phone.slice(0, 3) + "****", purpose);
    return json({ ok: true, expires_in_sec: CODE_TTL_MIN * 60 });
  }
  const text = `[PawMate] 인증번호 ${code} (5분 내 입력)`;
  const result = await sendSms(cfg!, phone, text);
  if (!result.ok) {
    console.error("solapi send failed", result.status, result.body);
    return json({ error: "sms_send_failed", detail: result.body }, 502);
  }

  return json({ ok: true, expires_in_sec: CODE_TTL_MIN * 60 });
});
