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
