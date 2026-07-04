// ============================================================================
// enroll-pet-identity — 펫 신원 인증(영상 → AI 검증 → 기준 프레임 저장) (0020, 미션 제거)
//   POST { petId, videoBase64, videoMime?, frames[], mimeType? }
//        Authorization: Bearer <login JWT>
//
//   ① 보호자 확인  ② pets 에서 등록 종/품종 읽기(클라 입력 불신)
//   ③ Gemini(영상): 실제 살아있는 개/고양이 + 영상 내내 동일 개체 (+ 참고 품종/털색)
//   ④ 등록정보 교차검증(종/품종=소프트 경고, 색=기록)
//   ⑤ 통과: 프레임 N장만 media 업로드 + enroll_pet_identity RPC.  ★ 영상은 저장하지 않음
//
//   --no-verify-jwt 배포. 영상은 Gemini 인라인 전송 후 메모리에서 소멸(Storage/DB 미기록).
//   ※ 동작 미션(challenge)은 AI 판별 오탐이 커서 제거. 스푸핑 차단은 실물·라이브 판별로 유지.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JWT_SECRET = Deno.env.get("JWT_SECRET");
const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY");

const ENROLL_REAL_THRESHOLD = 0.70;
const GEMINI_MODEL = "gemini-2.5-pro"; // 유료 등급(billing) — 영상/이미지 멀티모달

/// Gemini 구조화 출력 호출 + 429(한도) 재시도(backoff).
async function geminiGenerate(parts: unknown[], schema: object): Promise<any> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
  const body = JSON.stringify({
    contents: [{ role: "user", parts }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: schema,
      temperature: 0,
    },
  });
  for (let attempt = 0;; attempt++) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY! },
      body,
    });
    if (res.status === 429 && attempt < 2) {
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
      continue;
    }
    if (!res.ok) {
      const t = await res.text().catch(() => "");
      throw new Error(`gemini ${res.status}: ${t.slice(0, 300)}`);
    }
    return await res.json();
  }
}

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

const clamp01 = (n: unknown) => Math.min(1, Math.max(0, Number(n) || 0));

const ENROLL_SCHEMA = {
  type: "object",
  properties: {
    species: { type: "string", enum: ["dog", "cat", "other", "none"] },
    dog_real: { type: "number" },
    cat_real: { type: "number" },
    dog_fake: { type: "number" },
    cat_fake: { type: "number" },
    consistent: { type: "boolean" },
    detected_breed: { type: "string" },
    coat_colors: { type: "array", items: { type: "string" } },
    reason: { type: "string" },
  },
  required: [
    "species", "dog_real", "cat_real", "dog_fake", "cat_fake",
    "consistent", "detected_breed", "coat_colors", "reason",
  ],
};

async function verifyEnrollmentVideo(videoBase64: string, videoMime: string) {
  const prompt =
    `이 영상은 반려동물 등록 인증용이다. 판단하라:
(1) 실제 살아있는 개/고양이인가(화면 재촬영·인쇄물·일러스트·인형·AI 생성은 fake) — dog_real/cat_real/dog_fake/cat_fake(0~1).
(2) 영상 내내 같은 한 마리(동일 개체)인가 → consistent.
(3) (참고) 추정 품종 detected_breed(한국어, 확실치 않으면 "믹스") 와 주요 털색 coat_colors(예: ["white","tan"]).
reason 한국어 80자 이내.`;
  const body = await geminiGenerate([
    { text: prompt },
    { inline_data: { mime_type: videoMime, data: videoBase64 } },
  ], ENROLL_SCHEMA);
  const txt = body?.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";
  const v = JSON.parse(txt);
  return {
    species: String(v.species ?? "none"),
    dog_real: clamp01(v.dog_real),
    cat_real: clamp01(v.cat_real),
    dog_fake: clamp01(v.dog_fake),
    cat_fake: clamp01(v.cat_fake),
    consistent: v.consistent === true,
    detected_breed: String(v.detected_breed ?? "").slice(0, 50),
    coat_colors: Array.isArray(v.coat_colors)
      ? v.coat_colors.map((s: unknown) => String(s)).slice(0, 6)
      : [],
    reason: String(v.reason ?? "").slice(0, 200),
  };
}

// 품종 느슨 비교(오경고 최소화) — 양쪽 소문자/공백제거 후 부분 포함이면 일치.
function looseBreedMatch(reg: string, ai: string): boolean {
  const a = reg.toLowerCase().replace(/\s/g, "");
  const b = ai.toLowerCase().replace(/\s/g, "");
  if (!a || !b) return true; // 한쪽이라도 비면 경고 안 함
  if (b.includes("믹스") || b.includes("mix")) return true; // 믹스는 관대
  return a.includes(b) || b.includes(a);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (!GEMINI_KEY) return json({ error: "server_misconfigured" }, 500);

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

  let p: {
    petId?: string;
    videoBase64?: string;
    videoMime?: string;
    frames?: string[];
    mimeType?: string;
  };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const petId = typeof p.petId === "string" ? p.petId : "";
  const videoBase64 = typeof p.videoBase64 === "string" ? p.videoBase64 : "";
  const videoMime = p.videoMime ?? "video/mp4";
  const frames = Array.isArray(p.frames) ? p.frames : [];
  const mimeType = p.mimeType ?? "image/jpeg";

  if (!petId) return json({ enrolled: false, reason: "missing_pet" }, 400);
  if (!videoBase64) return json({ enrolled: false, reason: "no_video" }, 400);
  if (frames.length < 3) return json({ enrolled: false, reason: "too_few_frames" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  // 1) 보호자 확인
  const { data: g } = await admin
    .from("pet_guardians")
    .select("id")
    .eq("pet_id", petId)
    .eq("user_id", uid)
    .maybeSingle();
  if (!g) return json({ enrolled: false, reason: "not_guardian" }, 403);

  // 1-1) 등록값(대조 기준)은 서버가 직접 읽는다
  const { data: pet } = await admin
    .from("pets")
    .select("species_kind, species")
    .eq("id", petId)
    .maybeSingle();
  const regType = (pet?.species_kind ?? "").toLowerCase(); // 'dog'|'cat'
  const regBreed = (pet?.species ?? "").trim();

  // 2) Gemini 영상 판별 (실물·라이브 + 동일 개체)
  let ai: Awaited<ReturnType<typeof verifyEnrollmentVideo>>;
  try {
    ai = await verifyEnrollmentVideo(videoBase64, videoMime);
  } catch (e) {
    console.error("gemini enroll failed", e);
    return json({ enrolled: false, reason: "ai_unavailable" });
  }
  const real = Math.max(ai.dog_real, ai.cat_real);
  const fake = Math.max(ai.dog_fake, ai.cat_fake);
  if (!(real >= ENROLL_REAL_THRESHOLD && real > fake)) {
    return json({ enrolled: false, reason: "not_real_pet", ai });
  }
  if (!ai.consistent) {
    return json({ enrolled: false, reason: "not_consistent_pet", ai });
  }

  const species = ai.dog_real >= ai.cat_real ? "dog" : "cat";

  // 2-1) 등록정보 교차검증(소프트 — 통과 여부에 영향 없음)
  const typeOk = !regType || regType === species;
  const breedOk = !regBreed || looseBreedMatch(regBreed, ai.detected_breed);
  const warnings: string[] = [];
  if (!typeOk) warnings.push("species_kind");
  if (!breedOk) warnings.push("breed");
  const infoMatch = { species_kind: typeOk, breed: breedOk, color: true, warnings };
  // ★ 이 시점 이후 videoBase64 는 더 이상 사용하지 않는다(저장 호출 없음 → 영상 소멸).

  // 3) 프레임 N장만 업로드
  const urls: string[] = [];
  const paths: string[] = [];
  for (let i = 0; i < frames.length; i++) {
    const path = `${uid}/pet_identity/${petId}/${i}.jpg`;
    const { error: upErr } = await admin.storage.from("media").upload(
      path,
      b64ToBytes(frames[i]),
      { contentType: mimeType, upsert: true },
    );
    if (upErr) {
      console.error("frame upload failed", upErr);
      return json({ error: "internal_error" }, 500);
    }
    paths.push(path);
    urls.push(admin.storage.from("media").getPublicUrl(path).data.publicUrl);
  }

  const { error: rpcErr } = await admin.rpc("enroll_pet_identity", {
    p_pet: petId,
    p_species: species,
    p_breed: ai.detected_breed,
    p_colors: ai.coat_colors,
    p_info_match: infoMatch,
    p_paths: paths,
    p_urls: urls,
  });
  if (rpcErr) {
    console.error("enroll_pet_identity rpc failed", rpcErr);
    return json({ error: "internal_error" }, 500);
  }

  return json({
    enrolled: true,
    species,
    breed: ai.detected_breed,
    colors: ai.coat_colors,
    frameCount: urls.length,
    frames: urls,
    infoMatch,
    warnings,
  });
});
