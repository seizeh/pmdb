// ============================================================================
// refresh — refresh 토큰 회전 → 새 access + refresh 쌍 발급
//   POST { refresh_token }
//   rt_rotate RPC(service_role)로 원자적 회전 + grace 유예(30s) + 유실 복구 처리.
//     rotated|grace|recovered → 새 쌍 발급 / invalid|expired|inactive|reuse_revoked → 401.
//     recovered = 회전 응답 유실 후 구 토큰 재시도(후속 미사용 확인) — 세션 복구.
//   verify_jwt=false: 만료된 access 를 갱신하는 단계이므로 access 검증 안 함.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  ACCESS_TTL_CAPABLE, clientIp, clientUa, randomToken, rateLimited,
  REFRESH_GRACE_SECONDS, sha256Hex, signAccess,
} from "../_shared/auth.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("JWT_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);

  let p: { refresh_token?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const raw = (p.refresh_token ?? "").trim();
  if (!raw) return json({ error: "missing_refresh_token" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const oldHash = await sha256Hex(raw);
  // 기본 레이트리밋: 토큰 해시 20/분(스푸핑 불가, grace 증폭 캡) + IP 120/분(보조, IP 식별 시만).
  const ip = clientIp(req);
  if (
    await rateLimited(supabase, `refresh:tok:${oldHash}`, 20, 60) ||
    (ip !== null && await rateLimited(supabase, `refresh:ip:${ip}`, 120, 60))
  ) {
    return json({ error: "rate_limited" }, 429);
  }

  const newRaw = randomToken();
  const { data, error } = await supabase.rpc("rt_rotate", {
    p_old_hash: oldHash,
    p_new_hash: await sha256Hex(newRaw),
    p_user_agent: clientUa(req),
    p_grace_seconds: REFRESH_GRACE_SECONDS,
  });
  if (error) {
    console.error("rt_rotate failed", error);
    return json({ error: "internal_error" }, 500);
  }
  const row = (data as Array<{ result: string; user_id: string | null; token_version: number | null }>)?.[0];
  if (row?.result === "recovered") {
    console.warn("refresh recovered lost rotation for", row.user_id); // 유실 빈도 모니터링용
  }
  if (!row || (row.result !== "rotated" && row.result !== "grace" && row.result !== "recovered")) {
    // 실패 사유는 서버 로그로만. 클라엔 일관된 단일 코드(토큰 상태 구분 노출 방지, logout 과 일관).
    console.warn("refresh rejected:", row?.result ?? "invalid");
    return json({ error: "invalid_refresh" }, 401);
  }

  const token = await signAccess(row.user_id!, row.token_version ?? 0, ACCESS_TTL_CAPABLE, secret);
  return json({ ok: true, token, refresh_token: newRaw, expires_in: ACCESS_TTL_CAPABLE });
});
