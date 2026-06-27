// ============================================================================
// verify-post-photo — 게시글 사진 동일개체 매칭 + 라이브니스 (0018→0020)
//   POST { imageBase64, mimeType?, lat, lng, accuracy?, isMocked?, petId }
//        Authorization: Bearer <login JWT>
//
//   ① 활동지역 인증 + 모의위치 + 촬영지 행정동==users.region_code (0018 유지)
//   ② 대상 펫의 기준 프레임(pet_identity_frames) 조회 — 없으면 pet_not_enrolled
//   ③ Gemini: 기준 프레임 N장 + 게시 사진 1장 → 동일 개체 여부 + 라이브니스
//   ④ identity_score>=IDENTITY_PASS_THRESHOLD AND is_real AND real>fake → 통과
//   ⑤ 통과: 사진 업로드 + record_photo_verification 토큰(pet_id, ai_match_score, ai_matched)
//
//   --no-verify-jwt 배포. 신원 등록은 enroll-pet-identity(영상)에서 처리(0020).
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

const AI_REAL_THRESHOLD = 0.70; // 라이브니스(실제 개/고양이) 하한
const IDENTITY_PASS_THRESHOLD = 0.63; // 동일 개체 통과선(중간신뢰)
const TOKEN_TTL_MIN = 15;
const REVERIFY_DAYS = 60;

function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

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
  const a3 = adm.region?.area3?.name ?? "";
  if (!a3 || !adm.code?.id) return null;
  return {
    regionCode: adm.code.id as string,
    regionName: a3 as string,
    address: [a1, a2, a3].filter(Boolean).join(" "),
  };
}

const clamp01 = (n: unknown) => Math.min(1, Math.max(0, Number(n) || 0));

const MATCH_SCHEMA = {
  type: "object",
  properties: {
    same_individual: { type: "boolean" },
    identity_score: { type: "number" },
    is_real: { type: "boolean" },
    dog_real: { type: "number" },
    cat_real: { type: "number" },
    dog_fake: { type: "number" },
    cat_fake: { type: "number" },
    reason: { type: "string" },
  },
  required: [
    "same_individual", "identity_score", "is_real",
    "dog_real", "cat_real", "dog_fake", "cat_fake", "reason",
  ],
};

const MATCH_PROMPT =
  `앞의 여러 장은 등록된 반려동물 A의 기준 사진이다. 마지막 1장이 같은 개체 A인지 판정하라.
- 각도·조명·성장에 따른 차이는 허용하되, 품종·무늬·색·체형을 종합해 identity_score(0~1)와 same_individual 을 정하라. 단정 어려우면 보수적으로.
- 동시에 마지막 사진이 화면 재촬영/인쇄물/AI 생성이 아닌 실사(라이브)인지 is_real 로, dog_real/cat_real/dog_fake/cat_fake(0~1)도 매겨라.
- reason 은 한국어 80자 이내.`;

async function matchIdentity(
  refB64: string[],
  shotB64: string,
  shotMime: string,
) {
  const parts: unknown[] = [{ text: MATCH_PROMPT }];
  for (const f of refB64) {
    parts.push({ inline_data: { mime_type: "image/jpeg", data: f } });
  }
  parts.push({ inline_data: { mime_type: shotMime, data: shotB64 } });

  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent";
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY! },
    body: JSON.stringify({
      contents: [{ role: "user", parts }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: MATCH_SCHEMA,
        temperature: 0,
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}`);
  const body = await res.json();
  const txt = body?.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";
  const v = JSON.parse(txt);
  return {
    same_individual: v.same_individual === true,
    identity_score: clamp01(v.identity_score),
    is_real: v.is_real === true,
    dog_real: clamp01(v.dog_real),
    cat_real: clamp01(v.cat_real),
    dog_fake: clamp01(v.dog_fake),
    cat_fake: clamp01(v.cat_fake),
    reason: String(v.reason ?? "").slice(0, 200),
  };
}

type MatchResult = Awaited<ReturnType<typeof matchIdentity>>;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  if (!JWT_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (!NAVER_KEY_ID || !NAVER_KEY) return json({ error: "server_misconfigured" }, 500);
  if (!GEMINI_KEY) return json({ error: "server_misconfigured" }, 500);

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: {
    imageBase64?: string;
    mimeType?: string;
    lat?: number;
    lng?: number;
    accuracy?: number;
    isMocked?: boolean;
    petId?: string;
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
  const petId = typeof p.petId === "string" ? p.petId : "";
  if (!imageBase64) return json({ error: "missing_image" }, 400);
  if (!petId) return json({ error: "missing_pet" }, 400);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return json({ error: "invalid_coords" }, 400);
  }
  const accuracy = Math.round(Number(p.accuracy ?? 0)) || 0;
  const isMocked = p.isMocked === true;

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  const logFail = (
    reason: string,
    opts: { regionCode?: string | null; regionMatched?: boolean; m?: MatchResult } = {},
  ) =>
    admin.rpc("record_photo_verification", {
      p_user: uid,
      p_lat: lat,
      p_lng: lng,
      p_accuracy: accuracy,
      p_region_code: opts.regionCode ?? null,
      p_region_matched: opts.regionMatched ?? false,
      p_species: null,
      p_dog_real: opts.m?.dog_real ?? 0,
      p_cat_real: opts.m?.cat_real ?? 0,
      p_dog_fake: opts.m?.dog_fake ?? 0,
      p_cat_fake: opts.m?.cat_fake ?? 0,
      p_ai_pass: false,
      p_ai_reason: opts.m?.reason ?? null,
      p_result: "fail",
      p_fail_reason: reason,
      p_image_url: null,
      p_image_path: null,
      p_ttl_min: TOKEN_TTL_MIN,
      p_pet_id: petId,
      p_purpose: "post",
      p_match_score: opts.m?.identity_score ?? 0,
      p_matched: false,
    });

  // 0) 보호자 확인
  const { data: guardian } = await admin
    .from("pet_guardians")
    .select("role")
    .eq("pet_id", petId)
    .eq("user_id", uid)
    .maybeSingle();
  if (!guardian) return json({ error: "forbidden" }, 403);

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

  // 4) 대상 펫 기준 프레임
  const { data: frameRows } = await admin
    .from("pet_identity_frames")
    .select("image_path")
    .eq("pet_id", petId)
    .order("frame_index");
  if (!frameRows?.length) {
    return json({ pass: false, reason: "pet_not_enrolled" });
  }
  const refB64: string[] = [];
  for (const f of frameRows) {
    const { data: blob, error } = await admin.storage
      .from("media")
      .download(f.image_path as string);
    if (error || !blob) {
      console.error("frame download failed", error);
      return json({ pass: false, reason: "pet_not_enrolled" });
    }
    refB64.push(bytesToB64(new Uint8Array(await blob.arrayBuffer())));
  }

  // 5) Gemini 동일개체 매칭 + 라이브니스
  let m: MatchResult;
  try {
    m = await matchIdentity(refB64, imageBase64, mimeType);
  } catch (e) {
    console.error("gemini match failed", e);
    return json({ pass: false, reason: "ai_unavailable" });
  }
  const real = Math.max(m.dog_real, m.cat_real);
  const fake = Math.max(m.dog_fake, m.cat_fake);
  const livenessOk = m.is_real && real > fake;
  const idOk = m.identity_score >= IDENTITY_PASS_THRESHOLD;
  if (!livenessOk) {
    await logFail("not_real_pet", { regionCode: geo.regionCode, regionMatched: true, m });
    return json({ pass: false, reason: "not_real_pet", ai: m });
  }
  if (!idOk) {
    await logFail("identity_mismatch", { regionCode: geo.regionCode, regionMatched: true, m });
    return json({ pass: false, reason: "identity_mismatch", ai: m });
  }
  const species = m.dog_real >= m.cat_real ? "dog" : "cat";

  // 6) 통과: 사진 업로드 + 토큰 발급
  const path = `${uid}/posts/${Date.now()}.jpg`;
  const { error: upErr } = await admin.storage.from("media").uploadBinary(
    path,
    b64ToBytes(imageBase64),
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
    p_dog_real: m.dog_real,
    p_cat_real: m.cat_real,
    p_dog_fake: m.dog_fake,
    p_cat_fake: m.cat_fake,
    p_ai_pass: true,
    p_ai_reason: m.reason,
    p_result: "pass",
    p_fail_reason: null,
    p_image_url: imageUrl,
    p_image_path: path,
    p_ttl_min: TOKEN_TTL_MIN,
    p_pet_id: petId,
    p_purpose: "post",
    p_match_score: m.identity_score,
    p_matched: true,
    p_match_reason: m.reason,
  });
  if (recErr) {
    console.error("record failed", recErr);
    return json({ error: "internal_error" }, 500);
  }

  return json({
    pass: true,
    token,
    imageUrl,
    matchedPetId: petId,
    species,
    matchScore: m.identity_score,
    expiresAt: new Date(Date.now() + TOKEN_TTL_MIN * 60_000).toISOString(),
  });
});
