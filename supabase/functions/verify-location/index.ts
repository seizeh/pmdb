// ============================================================================
// verify-location — GPS 현장 동네 인증 (0017)
//   POST { lat, lng, accuracy?, isMocked? }   Authorization: Bearer <login JWT>
//
//   ① 커스텀 JWT(HS256, JWT_SECRET) 수동 검증 → sub = uid
//   ② users.location_verify_blocked_until 차단 확인
//   ③ 모의위치(isMocked) 거절
//   ④ Naver Reverse Geocoding(admcode) → region_code + 시/구/동 라벨
//   ⑤ record_location_verification RPC(service_role) 로 결과 반영
//
//   --no-verify-jwt 로 배포한다(login/phone 함수와 동일). 인증 컬럼은 클라이언트
//   GRANT 가 없어 이 함수(service_role) 경로로만 변경된다.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NAVER_KEY_ID = Deno.env.get("NAVER_MAP_KEY_ID");
const NAVER_KEY = Deno.env.get("NAVER_MAP_KEY");

const FAIL_LIMIT = 5; // 연속 실패 임계
const BLOCK_MINUTES = 60; // 차단 시간(분)

// base64url 디코딩 → 바이트
function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// 커스텀 로그인 JWT(HS256) 검증 → sub(uid). 실패 시 null.
async function getUidFromJwt(req: Request, secret: string): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const parts = m[1].split(".");
  if (parts.length !== 3) return null;
  const [encHeader, encPayload, encSig] = parts;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    "HMAC",
    key,
    b64urlToBytes(encSig),
    new TextEncoder().encode(`${encHeader}.${encPayload}`),
  );
  if (!valid) return null;

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(encPayload)));
  } catch {
    return null;
  }
  const nowSec = Math.floor(Date.now() / 1000);
  if (typeof payload.exp === "number" && payload.exp < nowSec) return null;
  return typeof payload.sub === "string" ? payload.sub : null;
}

// Naver Reverse Geocoding → 행정동코드 + 라벨. 실패/해상 등은 null.
async function reverseGeocode(lng: number, lat: number) {
  const url =
    "https://naveropenapi.apigw.ntruss.com/map-reversegeocode/v2/gc" +
    `?coords=${lng},${lat}&output=json&orders=admcode,legalcode,addr`;
  let res: Response;
  try {
    res = await fetch(url, {
      headers: {
        "x-ncp-apigw-api-key-id": NAVER_KEY_ID!,
        "x-ncp-apigw-api-key": NAVER_KEY!,
      },
    });
  } catch {
    return null;
  }
  if (!res.ok) return null;

  let body: any;
  try {
    body = await res.json();
  } catch {
    return null;
  }
  if (body?.status?.code !== 0 || !Array.isArray(body.results)) return null;

  const adm = body.results.find((r: any) => r.name === "admcode");
  if (!adm) return null;

  const a1 = adm.region?.area1?.name ?? "";
  const a2 = adm.region?.area2?.name ?? "";
  const a3 = adm.region?.area3?.name ?? ""; // 행정동
  if (!a3 || !adm.code?.id) return null; // 바다/주소 없음 등

  return {
    regionCode: adm.code.id as string, // 예: "4159011000"
    regionName: a3 as string, // 예: "동탄2동"
    address: [a1, a2, a3].filter(Boolean).join(" "),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  if (!JWT_SECRET) {
    console.error("JWT_SECRET 미설정");
    return json({ error: "server_misconfigured" }, 500);
  }
  if (!NAVER_KEY_ID || !NAVER_KEY) {
    console.error("NAVER_MAP_KEY(_ID) 미설정");
    return json({ error: "server_misconfigured" }, 500);
  }

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: { lat?: number; lng?: number; accuracy?: number; isMocked?: boolean };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const lat = Number(p.lat);
  const lng = Number(p.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return json({ error: "invalid_coords" }, 400);
  }
  const accuracy = Math.round(Number(p.accuracy ?? 0)) || 0;
  const isMocked = p.isMocked === true;

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  // 2) 차단 여부
  const { data: u } = await admin
    .from("users")
    .select("location_verify_blocked_until")
    .eq("id", uid)
    .single();
  if (
    u?.location_verify_blocked_until &&
    new Date(u.location_verify_blocked_until) > new Date()
  ) {
    return json({
      verified: false,
      reason: "blocked",
      blockedUntil: u.location_verify_blocked_until,
    });
  }

  const recordFail = (reason: string) =>
    admin.rpc("record_location_verification", {
      p_user: uid,
      p_lat: lat,
      p_lng: lng,
      p_accuracy: accuracy,
      p_result: "failed",
      p_fail_reason: reason,
      p_region_code: null,
      p_address: null,
      p_fail_limit: FAIL_LIMIT,
      p_block_minutes: BLOCK_MINUTES,
    });

  // 3) 모의위치
  if (isMocked) {
    await recordFail("mock_location");
    return json({ verified: false, reason: "mock_location" });
  }

  // 4) Naver 역지오코딩
  const geo = await reverseGeocode(lng, lat);
  if (!geo) {
    await recordFail("geocode_failed");
    return json({ verified: false, reason: "geocode_failed" });
  }

  // 5) 성공 반영
  const { error } = await admin.rpc("record_location_verification", {
    p_user: uid,
    p_lat: lat,
    p_lng: lng,
    p_accuracy: accuracy,
    p_result: "success",
    p_fail_reason: null,
    p_region_code: geo.regionCode,
    p_address: geo.address,
    p_fail_limit: FAIL_LIMIT,
    p_block_minutes: BLOCK_MINUTES,
  });
  if (error) {
    console.error("record_location_verification failed", error);
    return json({ error: "internal_error" }, 500);
  }

  return json({
    verified: true,
    regionCode: geo.regionCode,
    regionName: geo.regionName,
    address: geo.address,
  });
});
