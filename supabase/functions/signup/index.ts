// ============================================================================
// signup — 회원가입(계정 생성)
//   POST { username, password, nickname, user_type, phone, marketing_opt_in? }
//   전화 인증(verify-phone-code) 완료된 번호만 가입 가능.
//   필수 약관 동의는 앱 가입 1단계에서 전부 받은 뒤 호출된다(terms_agreed_at 기록).
//   비밀번호는 여기서 argon2id 해싱(_shared/passwords), INSERT 는 signup_user RPC.
//   service_role 로만 RPC 호출(클라이언트는 publishable 키로 이 함수만 호출).
//   verify_jwt=false: 로그인 전 단계. 남용은 전화 인증 선행 + 유니크 제약으로 방어.
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

const USER_TYPES = new Set(["pet_owner", "no_pet", "business"]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let p: {
    username?: string;
    password?: string;
    nickname?: string;
    user_type?: string;
    phone?: string;
    marketing_opt_in?: boolean;
  };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const username = (p.username ?? "").trim();
  const password = p.password ?? "";
  const nickname = (p.nickname ?? "").trim();
  const userType = p.user_type ?? "";
  const phone = normalizePhone(p.phone ?? "");

  // 입력 검증
  if (!/^[A-Za-z0-9]{4,20}$/.test(username)) {
    return json({ error: "invalid_username" }, 400);
  }
  if (password.length < 8 || !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
    return json({ error: "invalid_password" }, 400);
  }
  if (nickname.length < 1 || nickname.length > 20) {
    return json({ error: "invalid_nickname" }, 400);
  }
  if (!USER_TYPES.has(userType)) {
    return json({ error: "invalid_user_type" }, 400);
  }
  if (!/^01\d{8,9}$/.test(phone)) {
    return json({ error: "invalid_phone" }, 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("signup_user", {
    p_username: username,
    p_password_hash: await hashPassword(password),
    p_nickname: nickname,
    p_user_type: userType,
    p_phone: phone,
    p_marketing: p.marketing_opt_in === true,
  });

  if (error) {
    const msg = error.message ?? "";
    // signup_user 가 raise 한 커스텀 에러코드 매핑
    if (msg.includes("phone_not_verified")) {
      return json({ error: "phone_not_verified" }, 403);
    }
    if (msg.includes("username_taken")) {
      return json({ error: "username_taken" }, 409);
    }
    if (msg.includes("nickname_taken")) {
      return json({ error: "nickname_taken" }, 409);
    }
    if (msg.includes("phone_taken")) {
      return json({ error: "phone_taken" }, 409);
    }
    console.error("signup_user failed", error);
    return json({ error: "internal_error" }, 500);
  }

  return json({ ok: true, user_id: data });
});
