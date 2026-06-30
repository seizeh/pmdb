// ============================================================================
// login — 아이디/비밀번호 로그인 → 커스텀 JWT 발급
//   POST { username, password }
//   login_user RPC(service_role) 로 비번 검증 → sub=user_id 인 HS256 JWT 서명.
//   클라이언트는 이 토큰을 모든 요청의 Authorization 으로 붙여 RLS(app.uid()) 통과.
//   JWT 서명키는 함수 시크릿 JWT_SECRET (Supabase JWT Secret) 에서 읽는다.
//   verify_jwt=false: 로그인 자체가 토큰 발급 단계.
//   username 은 본인 화면 표시용으로만 응답에 포함(공개 프로필엔 노출하지 않음).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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

// base64url 인코딩 (패딩 제거)
function b64url(input: ArrayBuffer | string): string {
  let bytes: Uint8Array;
  if (typeof input === "string") {
    bytes = new TextEncoder().encode(input);
  } else {
    bytes = new Uint8Array(input);
  }
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function signJwt(
  payload: Record<string, unknown>,
  secret: string,
): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const encHeader = b64url(JSON.stringify(header));
  const encPayload = b64url(JSON.stringify(payload));
  const data = `${encHeader}.${encPayload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return `${data}.${b64url(sig)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) {
    console.error("JWT_SECRET 미설정");
    return json({ error: "server_misconfigured" }, 500);
  }

  let p: { username?: string; password?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const username = (p.username ?? "").trim();
  const password = p.password ?? "";
  if (!username || !password) return json({ error: "missing_fields" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("login_user", {
    p_username: username,
    p_password: password,
  });
  if (error) {
    console.error("login_user failed", error);
    return json({ error: "internal_error" }, 500);
  }
  const rows = (data as Array<{ id: string; username: string; nickname: string; user_type: string }>) ?? [];
  if (rows.length === 0) {
    return json({ error: "invalid_credentials" }, 401);
  }
  const user = rows[0];

  const nowSec = Math.floor(Date.now() / 1000);
  const token = await signJwt({
    sub: user.id,
    role: "authenticated",
    aud: "authenticated",
    iss: "supabase",
    iat: nowSec,
    exp: nowSec + 60 * 60 * 24 * 7, // 7일 (유출 토큰 노출창 축소. 정지/차단 즉시반영은 app.uid 상태게이트로 보강)
  }, secret);

  return json({
    ok: true,
    token,
    user: { id: user.id, username: user.username, nickname: user.nickname, user_type: user.user_type },
  });
});
