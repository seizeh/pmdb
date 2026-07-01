// ============================================================================
// login — 아이디/비밀번호 로그인 → 커스텀 access JWT (+ capability 시 refresh) 발급
//   POST { username, password }   [헤더 x-client-refresh: 1 → refresh 지원 클라]
//   login_user RPC(service_role)로 비번 검증(이미 status='active'만).
//   - 모든 토큰에 tv=users.token_version 클레임 stamp(레거시 분기 포함 — 필수).
//   - x-client-refresh:1 → access 8h + refresh(불투명, 해시저장) 발급.
//     미지원(레거시) → access 30일만(무중단). refresh 미지원 클라 하위호환.
//   verify_jwt=false: 로그인 자체가 토큰 발급 단계.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  ACCESS_TTL_CAPABLE, ACCESS_TTL_LEGACY, clientIp, clientUa, randomToken,
  rateLimited, sha256Hex, signAccess,
} from "../_shared/auth.ts";

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

  // 기본 레이트리밋: 계정 10/5분(스푸핑 불가, 1차) + IP 20/분(보조, IP 식별 시만).
  const ip = clientIp(req);
  if (
    await rateLimited(supabase, `login:user:${username.toLowerCase()}`, 10, 300) ||
    (ip !== null && await rateLimited(supabase, `login:ip:${ip}`, 20, 60))
  ) {
    return json({ error: "rate_limited" }, 429);
  }

  const { data, error } = await supabase.rpc("login_user", {
    p_username: username,
    p_password: password,
  });
  if (error) {
    console.error("login_user failed", error);
    return json({ error: "internal_error" }, 500);
  }
  const rows = (data as Array<{ id: string; username: string; nickname: string; user_type: string }>) ?? [];
  if (rows.length === 0) return json({ error: "invalid_credentials" }, 401);
  const user = rows[0];

  // 모든 토큰에 현재 token_version stamp(레거시 포함) — 미stamp 시 bump된 사용자 잠김.
  // ⚠ 조회 실패 시 tv 를 0 으로 추측 stamp 하면 tv>0 사용자가 즉시 잠기므로, 실패는 500 으로.
  const capable = req.headers.get("x-client-refresh") === "1";
  let tv: number;
  let refreshToken: string | undefined;
  if (capable) {
    // rt_issue 가 현재 token_version 을 반환 → 별도 조회 불필요(중복 제거).
    refreshToken = randomToken();
    const { data: tvData, error: rtErr } = await supabase.rpc("rt_issue", {
      p_user: user.id,
      p_token_hash: await sha256Hex(refreshToken),
      p_user_agent: clientUa(req),
    });
    if (rtErr) {
      console.error("rt_issue failed", rtErr);
      return json({ error: "internal_error" }, 500);
    }
    tv = (tvData as number | null) ?? 0;
  } else {
    const { data: uRow, error: uErr } = await supabase
      .from("users").select("token_version").eq("id", user.id).single();
    if (uErr || !uRow) {
      console.error("token_version fetch failed", uErr);
      return json({ error: "internal_error" }, 500);
    }
    tv = (uRow.token_version as number | undefined) ?? 0;
  }

  const ttl = capable ? ACCESS_TTL_CAPABLE : ACCESS_TTL_LEGACY;
  const token = await signAccess(user.id, tv, ttl, secret);

  return json({
    ok: true,
    token,
    refresh_token: refreshToken, // 레거시면 undefined → 응답에서 생략
    expires_in: ttl,
    user: { id: user.id, username: user.username, nickname: user.nickname, user_type: user.user_type },
  });
});
