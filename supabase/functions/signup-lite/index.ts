// ============================================================================
// signup-lite — 간이 회원(후기 전용) 인증 + 계정 확보 + 단명 토큰 발급 (0029 P0)
//   POST { phone, code, privacy_consent: true }
//   → { ok, token, expires_in, user: { id, display_name } }
//
// **왜 verify-phone-code 를 따로 부르지 않고 여기서 코드까지 검증하나**
//   verify-phone-code 는 코드를 사용처리만 하고 끝난다. 그 뒤 별도 호출로 세션을
//   발급하면, 그 사이 같은 번호로 아무나 signup-lite 를 때려 **남이 받은 인증으로
//   세션을 가로챌 수 있다**(정식 signup 은 비밀번호가 한 겹 더 있어 이 창이 없다).
//   간이 경로는 코드 소지가 곧 로그인이므로 검증·계정·토큰을 한 호출에 묶는다.
//
// **토큰이 짧은 이유(LITE_TTL=15분)**
//   간이 회원은 세션을 들고 다니지 않는다. 후기 한 건을 쓰는 동안만 유효하고,
//   다음 후기를 쓰려면 문자 인증을 다시 받는다. DB 쪽 add_facility_review 도
//   같은 15분 창의 review 인증을 요구하므로 둘이 어긋나지 않는다.
//
// **권한 범위는 계정 상태가 아니라 토큰 클레임이 정한다 — 20260803180000**
//   새로 만드는 계정은 users.status='lite' 라 app.uid() 에서 제외되지만, 아래 3)이
//   설명하듯 **기존 정식 회원(status='active')도 그대로 반환**된다. 그때 발급되는
//   토큰은 app.uid() 조건을 완전히 충족해서, "후기만 쓸 수 있는 토큰" 이 실제로는
//   채팅·게시글·펫·프로필 전부에 통했다(2026-08-03 감사에서 발견).
//   그래서 토큰에 `lite: true` 를 박는다 — app.uid() 가 이 클레임을 거부하고
//   app.uid_lite() 만 통과시키므로, 계정 상태와 무관하게 후기 3종으로 제한된다.
// verify_jwt=true: 다른 전화 인증 함수와 같이 publishable 키를 얇은 남용 게이트로.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { clientIp, rateLimited, signAccess } from "../_shared/auth.ts";
import { normalizePhone } from "../_shared/solapi.ts";

const LITE_TTL = 60 * 15; // 15분 — DB 의 reverify 창(add_facility_review)과 동일

/// 표시명 — app.mask_phone 과 같은 규칙(010 전체 가림 + 가운데 앞 1 + 끝 2).
/// DB 와 규칙이 갈리면 작성 화면 미리보기와 목록 표시가 달라지므로 함께 고쳐야 한다.
function maskPhone(phone: string): string {
  const d = phone.replace(/\D/g, "");
  if (d.length < 4) return "***-****-****";
  if (d.length >= 11) return `***-${d[3]}***-**${d.slice(-2)}`;
  return `***-****-**${d.slice(-2)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) {
    console.error("JWT_SECRET 미설정");
    return json({ error: "server_misconfigured" }, 500);
  }

  let p: { phone?: string; code?: string; privacy_consent?: boolean };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const phone = normalizePhone(p.phone ?? "");
  const code = (p.code ?? "").trim();
  if (!/^01\d{8,9}$/.test(phone)) return json({ error: "invalid_phone" }, 400);
  if (!/^\d{6}$/.test(code)) return json({ error: "invalid_code" }, 400);
  // 동의는 서버에서도 막는다 — 클라이언트 체크박스는 우회 가능하다.
  if (p.privacy_consent !== true) return json({ error: "privacy_consent_required" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 코드 대입 방어: 번호당 10회/10분(스푸핑 불가) + IP 30회/10분(보조).
  const ip = clientIp(req);
  if (
    await rateLimited(supabase, `lite:phone:${phone}`, 10, 600) ||
    (ip !== null && await rateLimited(supabase, `lite:ip:${ip}`, 30, 600))
  ) {
    return json({ error: "rate_limited" }, 429);
  }

  // 1) 미사용·미만료 최신 review 코드 확인
  const { data: pv, error: pvErr } = await supabase
    .from("phone_verifications")
    .select("id, code")
    .eq("phone", phone)
    .eq("purpose", "review")
    .eq("is_used", false)
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (pvErr) {
    console.error("verify query failed", pvErr);
    return json({ error: "internal_error" }, 500);
  }
  if (!pv || pv.code !== code) {
    return json({ verified: false, error: "code_mismatch_or_expired" }, 400);
  }

  // 2) 사용 처리(재사용 방지). 여기서 실패하면 토큰을 주면 안 된다.
  const { error: usedErr } = await supabase
    .from("phone_verifications").update({ is_used: true }).eq("id", pv.id);
  if (usedErr) {
    console.error("mark used failed", usedErr);
    return json({ error: "internal_error" }, 500);
  }

  // 3) 계정 확보 — 같은 번호면 기존 계정을 그대로 돌려준다(정식 회원 포함).
  //    덕분에 방문 회차(visit_no)가 끊기지 않는다.
  const { data: uid, error: suErr } = await supabase.rpc("signup_lite_user", {
    p_phone: phone,
    p_privacy_consent: true,
  });
  if (suErr) {
    const msg = suErr.message ?? "";
    if (msg.includes("account_unavailable")) return json({ error: "account_unavailable" }, 403);
    if (msg.includes("privacy_consent_required")) {
      return json({ error: "privacy_consent_required" }, 400);
    }
    if (msg.includes("phone_not_verified")) return json({ error: "phone_not_verified" }, 403);
    console.error("signup_lite_user failed", suErr);
    return json({ error: "internal_error" }, 500);
  }

  // 4) tv 클레임 — 미stamp 하면 token_version 이 올라간 계정이 즉시 잠긴다.
  //    (정식 회원이 간이 경로로 들어온 경우 tv 가 0 이 아닐 수 있다.)
  const { data: uRow, error: uErr } = await supabase
    .from("users").select("token_version").eq("id", uid).single();
  if (uErr || !uRow) {
    console.error("token_version fetch failed", uErr);
    return json({ error: "internal_error" }, 500);
  }

  // 5) 간이 전용 클레임. 이 한 줄이 "후기만 쓸 수 있다" 를 **실제로** 만든다 —
  //    계정이 active 든 lite 든 app.uid() 는 이 토큰을 거부한다(20260803180000).
  //    빼면 정식 회원 계정에 대한 완전 세션이 다시 발급된다.
  const token = await signAccess(
    uid as string, (uRow.token_version as number | undefined) ?? 0, LITE_TTL, secret,
    { lite: true },
  );

  return json({
    ok: true,
    token,
    expires_in: LITE_TTL,
    user: { id: uid, display_name: maskPhone(phone) },
  });
});
