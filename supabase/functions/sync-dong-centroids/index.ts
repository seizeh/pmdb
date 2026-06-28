// ============================================================================
// sync-dong-centroids — 행정동 중심좌표 채우기(동 이름 지오코딩) (0021 §6)
//   POST {}   Authorization: Bearer <login JWT>
//
//   centroid 미보유 행정동(dong_centroid_seeds)에 대해 seed 좌표를 역지오코딩해
//   "시 구 동" 이름을 얻고, 그 이름을 다시 정지오코딩해 동 대표좌표를 구해
//   dong_centroids 에 upsert 한다. 멱등(이미 있으면 대상 아님) — 아무나 호출해도
//   비어있는 동만 보충한다. 키는 서버 시크릿(NCP Maps). --no-verify-jwt 배포.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NAVER_KEY_ID = Deno.env.get("NAVER_MAP_KEY_ID");
const NAVER_KEY = Deno.env.get("NAVER_MAP_KEY");

function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function getUidFromJwt(req: Request, secret: string): Promise<string | null> {
  const m = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const parts = m[1].split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify(
    "HMAC", key, b64urlToBytes(s), new TextEncoder().encode(`${h}.${p}`));
  if (!ok) return null;
  try {
    const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(p)));
    if (typeof payload.exp === "number" && payload.exp < Math.floor(Date.now() / 1000)) return null;
    return typeof payload.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
}

// 좌표 → "시 구 동" 이름
async function reverseArea(lng: number, lat: number): Promise<string | null> {
  if (!NAVER_KEY_ID || !NAVER_KEY) return null;
  const url = "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc" +
    `?coords=${lng},${lat}&output=json&orders=admcode,legalcode,addr`;
  try {
    const res = await fetch(url, {
      headers: { "x-ncp-apigw-api-key-id": NAVER_KEY_ID, "x-ncp-apigw-api-key": NAVER_KEY },
    });
    if (!res.ok) return null;
    const body = await res.json();
    if (body?.status?.code !== 0 || !Array.isArray(body.results)) return null;
    const adm = body.results.find((r: any) => r.name === "admcode");
    const a1 = adm?.region?.area1?.name ?? "";
    const a2 = adm?.region?.area2?.name ?? "";
    const a3 = adm?.region?.area3?.name ?? "";
    const name = [a1, a2, a3].filter(Boolean).join(" ").trim();
    return name || null;
  } catch {
    return null;
  }
}

// "시 구 동" 이름 → 대표좌표(정지오코딩)
async function forwardGeocode(query: string): Promise<{ lng: number; lat: number } | null> {
  if (!NAVER_KEY_ID || !NAVER_KEY) return null;
  const url = "https://maps.apigw.ntruss.com/map-geocode/v2/geocode" +
    `?query=${encodeURIComponent(query)}`;
  try {
    const res = await fetch(url, {
      headers: { "x-ncp-apigw-api-key-id": NAVER_KEY_ID, "x-ncp-apigw-api-key": NAVER_KEY },
    });
    if (!res.ok) return null;
    const body = await res.json();
    const a = Array.isArray(body?.addresses) ? body.addresses[0] : null;
    if (!a) return null;
    const lng = Number(a.x), lat = Number(a.y);
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
    return { lng, lat };
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (!NAVER_KEY_ID || !NAVER_KEY) return json({ error: "server_misconfigured" }, 500);

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);
  const { data: seeds, error } = await supabase.rpc("dong_centroid_seeds");
  if (error) return json({ error: "seeds_failed", detail: error.message }, 500);

  let added = 0;
  for (const s of (seeds ?? []) as any[]) {
    const seedLng = Number(s.seed_lng), seedLat = Number(s.seed_lat);
    const name = await reverseArea(seedLng, seedLat);
    const fwd = name ? await forwardGeocode(name) : null;
    const coord = fwd ?? { lng: seedLng, lat: seedLat };
    const { error: upErr } = await supabase.from("dong_centroids").upsert({
      region_code: s.region_code,
      name,
      lng: coord.lng,
      lat: coord.lat,
      source: fwd ? "geocode" : "seed",
      updated_at: new Date().toISOString(),
    });
    if (!upErr) added++;
  }
  return json({ added });
});
