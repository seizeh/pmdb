// ============================================================================
// sync-dong-centroids — 행정동 중심좌표 채우기(동 이름 지오코딩) (0021 §6)
//   POST {}   header: x-sync-secret == DONG_SYNC_SECRET
//
//   centroid 미보유 행정동(dong_centroid_seeds)에 대해 seed 좌표를 역지오코딩해
//   "시 구 동" 이름을 얻고, 그 이름을 다시 정지오코딩해 동 대표좌표를 구해
//   dong_centroids 에 upsert 한다. 멱등 — 시드가 없으면 외부 호출 0회로 끝난다.
//
//   호출: pg_cron `dong-centroid-sweep`(매시) + pg_net (push-sweep 패턴,
//   설정은 app.dong_sync_config). 2026-09-20 전까지는 앱이 지도 클러스터를 그릴 때
//   로그인 JWT 로 직접 호출하는 lazy backfill 이었다 — 사용자 신원이 판정에 아무
//   역할이 없는 유지보수 작업이라 시스템 배치(시크릿 게이트)로 옮겼다. 채움이 최대
//   1시간 늦어지는 대가는 posts_by_region 의 사용자 평균 폴백이 흡수한다.
//   구버전 앱의 JWT 호출은 401 — 앱 쪽이 fire-and-forget + ignored 라 무증상.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { secretEq } from "../_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const DONG_SYNC_SECRET = Deno.env.get("DONG_SYNC_SECRET");
const NAVER_KEY_ID = Deno.env.get("NAVER_MAP_KEY_ID");
const NAVER_KEY = Deno.env.get("NAVER_MAP_KEY");

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
  if (!DONG_SYNC_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (!NAVER_KEY_ID || !NAVER_KEY) return json({ error: "server_misconfigured" }, 500);

  // 시스템 배치 게이트 — 크론(pg_net)과 공유하는 시크릿. 사용자 레이트리밋은
  // 호출 주체가 크론뿐이 되면서 필요가 사라졌다(매시 1회가 곧 상한).
  if (!secretEq(req.headers.get("x-sync-secret") ?? "", DONG_SYNC_SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  const { data: seeds, error } = await admin.rpc("dong_centroid_seeds");
  if (error) return json({ error: "seeds_failed", detail: error.message }, 500);

  let added = 0;
  for (const s of (seeds ?? []) as any[]) {
    const seedLng = Number(s.seed_lng), seedLat = Number(s.seed_lat);
    const name = await reverseArea(seedLng, seedLat);
    const fwd = name ? await forwardGeocode(name) : null;
    const coord = fwd ?? { lng: seedLng, lat: seedLat };
    const { error: upErr } = await admin.from("dong_centroids").upsert({
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
