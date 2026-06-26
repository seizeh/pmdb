// ============================================================================
// verify-post-photo — 게시글 사진 실존 검증 (0018)
//   POST { imageBase64, mimeType?, lat, lng, accuracy?, isMocked? }
//        Authorization: Bearer <login JWT>
//
//   ① 커스텀 JWT(HS256, JWT_SECRET) 수동 검증 → sub = uid
//   ② 활동지역 인증 상태(0017): is_location_verified & 미만료 & region_code 존재
//   ③ 모의위치(isMocked) 거절
//   ④ Naver Reverse Geocoding(admcode) → 촬영지 region_code == users.region_code
//   ⑤ Gemini 2.5 Pro 로 실제 살아있는 개/고양이 판별
//   ⑥ 통과: service_role 로 media 버킷에 원본 업로드 + record_photo_verification(토큰 발급)
//
//   --no-verify-jwt 로 배포한다(login/verify-location 과 동일). AI 키·이미지 원본은
//   서버만 본다. 통과한 바이트를 서버가 직접 업로드해 "AI가 본 사진 == 게시 사진" 보장.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NAVER_KEY_ID = Deno.env.get("NAVER_MAP_KEY_ID");
const NAVER_KEY = Deno.env.get("NAVER_MAP_KEY");
const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY");

const AI_PASS_THRESHOLD = 0.70; // 운영 중 튜닝 대상(0.6~0.8)
const TOKEN_TTL_MIN = 15; // 토큰 유효시간(분)
const REVERIFY_DAYS = 60; // 활동지역 인증 만료(0017 정책과 일치)

// base64url 디코딩 → 바이트 (verify-location 과 동일)
function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// 커스텀 로그인 JWT(HS256) 검증 → sub(uid). 실패 시 null. (verify-location 과 동일)
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

// Naver Reverse Geocoding → 행정동코드 + 라벨. (verify-location 과 동일)
async function reverseGeocode(lng: number, lat: number) {
  const url =
    "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc" +
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

const clamp01 = (n: unknown) => Math.min(1, Math.max(0, Number(n) || 0));

// Gemini 2.5 Pro 구조화 출력 — 실제 살아있는 개/고양이 판별.
const GEMINI_SCHEMA = {
  type: "object",
  properties: {
    species: { type: "string", enum: ["dog", "cat", "other", "none"] },
    dog_real: { type: "number" },
    cat_real: { type: "number" },
    dog_fake: { type: "number" },
    cat_fake: { type: "number" },
    reason: { type: "string" },
  },
  required: ["species", "dog_real", "cat_real", "dog_fake", "cat_fake", "reason"],
};

const GEMINI_PROMPT =
  `이 사진에 실제로 살아있는 개 또는 고양이가 물리적으로 존재하는지 판별해라.
- 화면 재촬영(모니터/휴대폰 화면), 인쇄물/사진의 사진, 일러스트·만화, 봉제인형·장난감,
  AI 생성 이미지는 fake 로 본다.
- 각 클래스 신뢰도(dog_real, cat_real, dog_fake, cat_fake)를 0~1로 매겨라.
- reason 은 한국어 80자 이내.`;

async function classifyPet(imageBase64: string, mimeType: string) {
  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent";
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY! },
    body: JSON.stringify({
      contents: [{
        role: "user",
        parts: [
          { text: GEMINI_PROMPT },
          { inline_data: { mime_type: mimeType, data: imageBase64 } },
        ],
      }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: GEMINI_SCHEMA,
        temperature: 0,
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}`);
  const body = await res.json();
  const txt = body?.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";
  const v = JSON.parse(txt);
  return {
    species: String(v.species ?? "none"),
    dog_real: clamp01(v.dog_real),
    cat_real: clamp01(v.cat_real),
    dog_fake: clamp01(v.dog_fake),
    cat_fake: clamp01(v.cat_fake),
    reason: String(v.reason ?? "").slice(0, 200),
  };
}

type AiResult = Awaited<ReturnType<typeof classifyPet>>;

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
  if (!GEMINI_KEY) {
    console.error("GEMINI_API_KEY 미설정");
    return json({ error: "server_misconfigured" }, 500);
  }

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: {
    imageBase64?: string;
    mimeType?: string;
    lat?: number;
    lng?: number;
    accuracy?: number;
    isMocked?: boolean;
  };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const imageBase64 = typeof p.imageBase64 === "string" ? p.imageBase64 : "";
  const mimeType = p.mimeType ?? "image/jpeg";
  const lat = Number(p.lat);
  const lng = Number(p.lng);
  if (!imageBase64) return json({ error: "missing_image" }, 400);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return json({ error: "invalid_coords" }, 400);
  }
  const accuracy = Math.round(Number(p.accuracy ?? 0)) || 0;
  const isMocked = p.isMocked === true;

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  // 실패 로그 헬퍼(검증 위치/AI 정보까지 함께 기록)
  const logFail = (
    reason: string,
    opts: { regionCode?: string | null; regionMatched?: boolean; ai?: AiResult } = {},
  ) =>
    admin.rpc("record_photo_verification", {
      p_user: uid,
      p_lat: lat,
      p_lng: lng,
      p_accuracy: accuracy,
      p_region_code: opts.regionCode ?? null,
      p_region_matched: opts.regionMatched ?? false,
      p_species: opts.ai?.species ?? null,
      p_dog_real: opts.ai?.dog_real ?? 0,
      p_cat_real: opts.ai?.cat_real ?? 0,
      p_dog_fake: opts.ai?.dog_fake ?? 0,
      p_cat_fake: opts.ai?.cat_fake ?? 0,
      p_ai_pass: false,
      p_ai_reason: opts.ai?.reason ?? null,
      p_result: "fail",
      p_fail_reason: reason,
      p_image_url: null,
      p_image_path: null,
      p_ttl_min: TOKEN_TTL_MIN,
    });

  // 1) 활동지역 인증 상태(0017)
  const { data: u } = await admin
    .from("users")
    .select("region_code, is_location_verified, last_verified_at, address")
    .eq("id", uid)
    .single();
  const expired = !u?.last_verified_at ||
    (Date.now() - new Date(u.last_verified_at).getTime()) > REVERIFY_DAYS * 864e5;
  if (!u?.is_location_verified || expired || !u?.region_code) {
    return json({ pass: false, reason: "not_verified" });
  }

  // 2) 모의위치
  if (isMocked) {
    await logFail("mock_location");
    return json({ pass: false, reason: "mock_location" });
  }

  // 3) 촬영지 역지오코딩 → 행정동 일치
  const geo = await reverseGeocode(lng, lat);
  if (!geo) {
    await logFail("geocode_failed");
    return json({ pass: false, reason: "geocode_failed" });
  }
  if (geo.regionCode !== u.region_code) {
    await logFail("region_mismatch", { regionCode: geo.regionCode });
    return json({
      pass: false,
      reason: "region_mismatch",
      expected: u.address ?? null,
      got: geo.regionName,
    });
  }

  // 4) Gemini 판별 (호출 실패/타임아웃은 ai_unavailable — 통과로 오인 금지)
  let ai: AiResult;
  try {
    ai = await classifyPet(imageBase64, mimeType);
  } catch (e) {
    console.error("gemini classify failed", e);
    return json({ pass: false, reason: "ai_unavailable" });
  }
  const real = Math.max(ai.dog_real, ai.cat_real);
  const fake = Math.max(ai.dog_fake, ai.cat_fake);
  const aiPass = real >= AI_PASS_THRESHOLD && real > fake;
  if (!aiPass) {
    await logFail("not_real_pet", { regionCode: geo.regionCode, regionMatched: true, ai });
    return json({ pass: false, reason: "not_real_pet", ai });
  }
  const species = ai.dog_real >= ai.cat_real ? "dog" : "cat";

  // 5) 통과: 서버가 직접 업로드(AI가 본 바이트 == 게시 바이트 보장)
  const path = `${uid}/posts/${Date.now()}.jpg`;
  const bytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
  const { error: upErr } = await admin.storage.from("media").uploadBinary(
    path,
    bytes,
    { contentType: mimeType, upsert: false },
  );
  if (upErr) {
    console.error("media upload failed", upErr);
    return json({ error: "internal_error" }, 500);
  }
  const imageUrl = admin.storage.from("media").getPublicUrl(path).data.publicUrl;

  const { data: token, error: recErr } = await admin.rpc("record_photo_verification", {
    p_user: uid,
    p_lat: lat,
    p_lng: lng,
    p_accuracy: accuracy,
    p_region_code: geo.regionCode,
    p_region_matched: true,
    p_species: species,
    p_dog_real: ai.dog_real,
    p_cat_real: ai.cat_real,
    p_dog_fake: ai.dog_fake,
    p_cat_fake: ai.cat_fake,
    p_ai_pass: true,
    p_ai_reason: ai.reason,
    p_result: "pass",
    p_fail_reason: null,
    p_image_url: imageUrl,
    p_image_path: path,
    p_ttl_min: TOKEN_TTL_MIN,
  });
  if (recErr) {
    console.error("record_photo_verification failed", recErr);
    return json({ error: "internal_error" }, 500);
  }

  return json({
    pass: true,
    token,
    imageUrl,
    species,
    expiresAt: new Date(Date.now() + TOKEN_TTL_MIN * 60_000).toISOString(),
  });
});
