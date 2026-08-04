// ============================================================================
// reset-password — 전화 OTP 인증 후 비밀번호 재설정
//   POST { phone, new_password }
//   전화 인증(verify-phone-code, purpose='password_reset')이 30분 내 완료된 번호만 허용.
//   새 비밀번호는 여기서 argon2id 해싱(_shared/passwords) 후 reset_password_user RPC 가
//   갱신 + 전 세션 무효화(token_version bump + refresh 회수)를 원자 처리.
//   verify_jwt=false: 로그인 전 단계. service_role 로만 RPC 호출.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { hashPassword } from "../_shared/passwords.ts";
import { clientIp, rateLimited } from "../_shared/auth.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOW_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// 국내 휴대폰 번호 정규화: 숫자만 남기고 +82/82 → 0
function normalizePhone(raw: string): string {
  let digits = (raw ?? "").replace(/[^\d]/g, "");
  if (digits.startsWith("82")) digits = "0" + digits.slice(2);
  return digits;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let p: { phone?: string; new_password?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const phone = normalizePhone(p.phone ?? "");
  const password = p.new_password ?? "";
  if (!/^01\d{8,9}$/.test(phone)) return json({ error: "invalid_phone" }, 400);
  if (password.length < 8 || !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
    return json({ error: "invalid_password" }, 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 이 엔드포인트는 **인증 없이 무제한으로 호출할 수 있는 오라클**이었다.
  // 403 phone_not_verified 와 200 ok 의 차이가 "이 번호가 최근 30분 안에 재설정을
  // 했는가" 를 공짜로 알려주므로, 번호 목록을 계속 찔러 보며 창이 열리기를 기다릴 수
  // 있었다. 인증 소진(20260803181000)이 창을 수 초로 줄였고, 여기서는 그 수 초를
  // 노린 폴링에 값을 매긴다 — 정상 사용자는 이 엔드포인트를 한 번만 부른다.
  // 값은 signup-lite·verify-phone-code 와 같은 축(번호 10/10분 + IP 30/10분).
  const ip = clientIp(req);
  if (
    await rateLimited(supabase, `pwreset:phone:${phone}`, 10, 600) ||
    (ip !== null && await rateLimited(supabase, `pwreset:ip:${ip}`, 30, 600))
  ) {
    return json({ error: "rate_limited" }, 429);
  }

  const { error } = await supabase.rpc("reset_password_user", {
    p_phone: phone,
    p_new_hash: await hashPassword(password),
  });

  if (error) {
    const msg = error.message ?? "";
    if (msg.includes("phone_not_verified")) return json({ error: "phone_not_verified" }, 403);
    if (msg.includes("user_not_found")) return json({ error: "user_not_found" }, 404);
    if (msg.includes("invalid_password")) return json({ error: "invalid_password" }, 400);
    console.error("reset_password_user failed", error);
    return json({ error: "internal_error" }, 500);
  }

  return json({ ok: true });
});
