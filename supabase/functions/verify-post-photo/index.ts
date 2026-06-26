// ============================================================================
// verify-post-photo — 게시글 사진 실존 + 펫 개체 일치 검증 (0018/0019)
//   POST { imageBase64, mimeType?, lat, lng, accuracy?, isMocked?, petId, purpose? }
//        Authorization: Bearer <login JWT>
//
//   purpose='reference' : 펫 AI 인증 "기준 사진" 등록(owner 전용). 실존+지역 검사 후
//                         서버 업로드 → pets.ai_ref_* 설정. 개체 대조 없음.
//   purpose='post'(기본): 게시글 사진. 펫 기준 사진과 Gemini 2장 대조 → 개체 일치도.
//                         실존+지역 통과면 게시 허용(소프트), 일치는 ai_matched 로 기록.
//
//   --no-verify-jwt 배포. AI 키·이미지 원본은 서버만 본다.
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

const AI_PASS_THRESHOLD = 0.70; // 실제 반려동물 판정
const MATCH_THRESHOLD = 0.60; // 개체 일치 판정(소프트)
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

// 바이트 → base64 (Gemini inline_data 용). 큰 이미지 대비 청크 처리.
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

const REAL_PROPS = {
  species: { type: "string", enum: ["dog", "cat", "other", "none"] },
  dog_real: { type: "number" },
  cat_real: { type: "number" },
  dog_fake: { type: "number" },
  cat_fake: { type: "number" },
  reason: { type: "string" },
};

const REAL_PROMPT =
  `이 사진에 실제로 살아있는 개 또는 고양이가 물리적으로 존재하는지 판별해라.
- 화면 재촬영(모니터/휴대폰 화면), 인쇄물/사진의 사진, 일러스트·만화, 봉제인형·장난감,
  AI 생성 이미지는 fake 로 본다.
- 각 클래스 신뢰도(dog_real, cat_real, dog_fake, cat_fake)를 0~1로 매겨라.
- reason 은 한국어 80자 이내.`;

const MATCH_PROMPT =
  `첫 번째 사진은 이 사용자가 등록한 반려동물의 "기준 사진"이고, 두 번째 사진은 방금 촬영한 사진이다.
(1) 두 번째(촬영) 사진에 실제로 살아있는 개/고양이가 있는지 dog_real/cat_real/dog_fake/cat_fake(0~1)로 판별.
    화면 재촬영·인쇄물·일러스트·인형·AI 생성은 fake.
(2) 두 사진이 같은 개체로 보이는지 match_score(0~1)와 same_pet 으로 판별.
    품종·털색·무늬·반점·체형을 종합. 단정 어려우면 보수적으로 낮게.
- reason 은 한국어 80자 이내(왜 그렇게 봤는지).`;

async function geminiJson(parts: unknown[], schema: object) {
  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent";
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY! },
    body: JSON.stringify({
      contents: [{ role: "user", parts }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: schema,
        temperature: 0,
      },
    }),
  });
  if (!res.ok) throw new Error(`gemini ${res.status}`);
  const body = await res.json();
  const txt = body?.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";
  return JSON.parse(txt);
}

function normReal(v: any) {
  return {
    species: String(v.species ?? "none"),
    dog_real: clamp01(v.dog_real),
    cat_real: clamp01(v.cat_real),
    dog_fake: clamp01(v.dog_fake),
    cat_fake: clamp01(v.cat_fake),
    reason: String(v.reason ?? "").slice(0, 200),
  };
}

// 실존 판별(1장) — 기준 사진 등록용
async function classifyPet(imageBase64: string, mimeType: string) {
  const v = await geminiJson(
    [{ text: REAL_PROMPT }, { inline_data: { mime_type: mimeType, data: imageBase64 } }],
    { type: "object", properties: REAL_PROPS, required: Object.keys(REAL_PROPS) },
  );
  return normReal(v);
}

// 실존 판별 + 개체 대조(2장) — 게시글 사진용
async function classifyAndMatch(
  refB64: string,
  refMime: string,
  shotB64: string,
  shotMime: string,
) {
  const schema = {
    type: "object",
    properties: {
      ...REAL_PROPS,
      same_pet: { type: "boolean" },
      match_score: { type: "number" },
      match_reason: { type: "string" },
    },
    required: [...Object.keys(REAL_PROPS), "same_pet", "match_score", "match_reason"],
  };
  const v = await geminiJson([
    { text: MATCH_PROMPT },
    { inline_data: { mime_type: refMime, data: refB64 } },
    { inline_data: { mime_type: shotMime, data: shotB64 } },
  ], schema);
  return {
    ...normReal(v),
    same_pet: v.same_pet === true,
    match_score: clamp01(v.match_score),
    match_reason: String(v.match_reason ?? "").slice(0, 200),
  };
}

type AiReal = ReturnType<typeof normReal>;

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
    purpose?: string;
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
  const purpose = p.purpose === "reference" ? "reference" : "post";
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
    opts: { regionCode?: string | null; regionMatched?: boolean; ai?: AiReal } = {},
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
      p_pet_id: petId,
      p_purpose: purpose,
    });

  // 0) 펫 소유/보호자 확인 (reference 는 owner 전용)
  const { data: pet } = await admin
    .from("pets")
    .select("id, primary_guardian_id, ai_ref_image_path")
    .eq("id", petId)
    .maybeSingle();
  if (!pet) return json({ error: "pet_not_found" }, 404);
  const { data: guardian } = await admin
    .from("pet_guardians")
    .select("role")
    .eq("pet_id", petId)
    .eq("user_id", uid)
    .maybeSingle();
  if (!guardian) return json({ error: "forbidden" }, 403);
  if (purpose === "reference" && guardian.role !== "owner") {
    return json({ error: "forbidden_not_owner" }, 403);
  }

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

  // ── purpose='reference': 기준 사진 등록 (실존만, 대조 없음) ──────────────
  if (purpose === "reference") {
    let ai: AiReal;
    try {
      ai = await classifyPet(imageBase64, mimeType);
    } catch (e) {
      console.error("gemini classify failed", e);
      return json({ pass: false, reason: "ai_unavailable" });
    }
    const real = Math.max(ai.dog_real, ai.cat_real);
    const fake = Math.max(ai.dog_fake, ai.cat_fake);
    if (!(real >= AI_PASS_THRESHOLD && real > fake)) {
      await logFail("not_real_pet", { regionCode: geo.regionCode, regionMatched: true, ai });
      return json({ pass: false, reason: "not_real_pet", ai });
    }

    const path = `${uid}/pets/ref/${Date.now()}.jpg`;
    const bytes = b64urlBytesPlain(imageBase64);
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
    const species = ai.dog_real >= ai.cat_real ? "dog" : "cat";

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
      p_pet_id: petId,
      p_purpose: "reference",
    });
    if (recErr) {
      console.error("record failed", recErr);
      return json({ error: "internal_error" }, 500);
    }
    const { error: setErr } = await admin.rpc("set_pet_ai_reference", {
      p_pet: petId,
      p_verification: token,
    });
    if (setErr) {
      console.error("set_pet_ai_reference failed", setErr);
      return json({ error: "internal_error" }, 500);
    }
    return json({ pass: true, imageUrl, species });
  }

  // ── purpose='post': 게시글 사진 — 기준 사진과 개체 대조 ──────────────────
  if (!pet.ai_ref_image_path) {
    return json({ pass: false, reason: "no_reference" });
  }
  const { data: refBlob, error: dlErr } = await admin.storage
    .from("media")
    .download(pet.ai_ref_image_path);
  if (dlErr || !refBlob) {
    console.error("reference download failed", dlErr);
    return json({ pass: false, reason: "no_reference" });
  }
  const refB64 = bytesToB64(new Uint8Array(await refBlob.arrayBuffer()));

  let m: Awaited<ReturnType<typeof classifyAndMatch>>;
  try {
    m = await classifyAndMatch(refB64, "image/jpeg", imageBase64, mimeType);
  } catch (e) {
    console.error("gemini match failed", e);
    return json({ pass: false, reason: "ai_unavailable" });
  }
  const real = Math.max(m.dog_real, m.cat_real);
  const fake = Math.max(m.dog_fake, m.cat_fake);
  if (!(real >= AI_PASS_THRESHOLD && real > fake)) {
    await logFail("not_real_pet", { regionCode: geo.regionCode, regionMatched: true, ai: m });
    return json({ pass: false, reason: "not_real_pet", ai: m });
  }
  const matched = m.match_score >= MATCH_THRESHOLD;
  const species = m.dog_real >= m.cat_real ? "dog" : "cat";

  // 통과(실존+지역) → 서버 업로드. 매칭은 소프트(낮아도 게시 허용).
  const path = `${uid}/posts/${Date.now()}.jpg`;
  const bytes = b64urlBytesPlain(imageBase64);
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
    p_match_score: m.match_score,
    p_matched: matched,
    p_match_reason: m.match_reason,
  });
  if (recErr) {
    console.error("record failed", recErr);
    return json({ error: "internal_error" }, 500);
  }

  return json({
    pass: true,
    token,
    imageUrl,
    species,
    matched,
    matchScore: m.match_score,
    expiresAt: new Date(Date.now() + TOKEN_TTL_MIN * 60_000).toISOString(),
  });
});

// base64(표준) → 바이트
function b64urlBytesPlain(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
