// ============================================================================
// search-petcafe — 애견카페 실시간 검색(네이버 지역검색 프록시) (0021)
//   POST { lat, lng }   Authorization: Bearer <login JWT>
//
//   공공데이터에 애견카페 전용 업종이 없어 네이버 지역검색 API 로 실시간 검색한다.
//   키(X-Naver-Client-Id/Secret)는 서버 시크릿에만 두고 앱에 노출하지 않는다.
//   결과는 최대 5건(지역검색 display 한계). 좌표는 WGS84 로 환산해 돌려준다.
//   --no-verify-jwt 배포 + JWT 수동 검증(login/verify-* 와 동일 패턴).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { activeUid, rateLimited } from "../_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// 유료 API(네이버 지역검색 + 역지오코딩) 호출 상한 — 사용자당.
// 지도 탭 진입·이름 검색(250ms 디바운스)에서 부르므로 정상 사용도 제법 잦다.
// 루프 호출만 잡을 만큼 넉넉히 둔다.
const SEARCH_MAX = 120;
const SEARCH_WINDOW_SEC = 3600;

const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NAVER_CLIENT_ID = Deno.env.get("NAVER_CLIENT_ID");
const NAVER_CLIENT_SECRET = Deno.env.get("NAVER_CLIENT_SECRET");
// 역지오코딩(현재 위치 → 구/동)으로 검색어를 지역 한정한다(NCP Maps 키, 기존 공유).
const NAVER_MAP_KEY_ID = Deno.env.get("NAVER_MAP_KEY_ID");
const NAVER_MAP_KEY = Deno.env.get("NAVER_MAP_KEY");

/// 좌표 → "시군구 읍면동" (지역검색어 한정용). 실패 시 null.
async function reverseGeocodeArea(lng: number, lat: number): Promise<string | null> {
  if (!NAVER_MAP_KEY_ID || !NAVER_MAP_KEY) return null;
  const url =
    "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc" +
    `?coords=${lng},${lat}&output=json&orders=admcode,legalcode,addr`;
  try {
    const res = await fetch(url, {
      headers: {
        "x-ncp-apigw-api-key-id": NAVER_MAP_KEY_ID,
        "x-ncp-apigw-api-key": NAVER_MAP_KEY,
      },
    });
    if (!res.ok) return null;
    const body = await res.json();
    if (body?.status?.code !== 0 || !Array.isArray(body.results)) return null;
    const adm = body.results.find((r: any) => r.name === "admcode");
    const a2 = adm?.region?.area2?.name ?? "";
    const a3 = adm?.region?.area3?.name ?? "";
    const area = [a2, a3].filter(Boolean).join(" ").trim();
    return area || null;
  } catch (_) {
    return null;
  }
}

const stripTags = (s: string) => (s ?? "").replace(/<[^>]+>/g, "").trim();

// 네이버 지역검색 mapx/mapy → WGS84. 현재 API 는 위경도×1e7 정수로 반환한다.
// (예: mapx="1270000000" → 127.0). 한국 bbox 밖이면 좌표 없음 처리.
function toWgs84(mapx: string, mapy: string): { lat: number; lng: number } | null {
  const x = Number(mapx), y = Number(mapy);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  const lng = x / 1e7, lat = y / 1e7;
  if (lng > 124 && lng < 132 && lat > 33 && lat < 39) return { lat, lng };
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (!NAVER_CLIENT_ID || !NAVER_CLIENT_SECRET) {
    return json({ error: "server_misconfigured" }, 500);
  }

  // 정지·회수·간이 토큰까지 걸러낸다(app.uid() 와 같은 판정) — service_role 로
  // 진행하므로 RLS 가 받아 주지 않는다.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
  const uid = await activeUid(req, JWT_SECRET, admin);
  if (!uid) return json({ error: "unauthorized" }, 401);

  // 유료 API 상한 — 호출 전에 소모한다(제한에 걸린 요청이 네이버로 나가지 않게).
  if (await rateLimited(admin, `geosearch:${uid}`, SEARCH_MAX, SEARCH_WINDOW_SEC)) {
    return json({ error: "rate_limited" }, 429);
  }

  let p: { lat?: number; lng?: number; query?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const lat = Number(p.lat), lng = Number(p.lng);
  const provided = (typeof p.query === "string") ? p.query.trim() : "";
  // query 가 오면 이름 검색(입력 그대로, 위치 무관) / 없으면 현재 동네 애견카페.
  // 후자는 위치 인자가 없는 지역검색 특성상 역지오코딩으로 지역을 한정한다.
  let query: string;
  if (provided) {
    query = provided;
  } else {
    const area = (Number.isFinite(lat) && Number.isFinite(lng))
      ? await reverseGeocodeArea(lng, lat)
      : null;
    query = (area ? area + " " : "") + "애견카페";
  }
  const url =
    "https://openapi.naver.com/v1/search/local.json?query=" +
    encodeURIComponent(query) + "&display=5&sort=comment";
  let res: Response;
  try {
    res = await fetch(url, {
      headers: {
        "X-Naver-Client-Id": NAVER_CLIENT_ID,
        "X-Naver-Client-Secret": NAVER_CLIENT_SECRET,
      },
    });
  } catch (_) {
    return json({ items: [], error: "naver_unreachable" });
  }
  if (!res.ok) {
    const t = await res.text().catch(() => "");
    console.error("naver local search", res.status, t.slice(0, 200));
    return json({ items: [], error: `naver_${res.status}` });
  }

  const body = await res.json();
  const items = (body.items as any[] ?? [])
    .map((it) => {
      // 애견카페로 인정할 분류만 통과(화이트리스트). 검색어가 "애견카페"여도
      // 네이버가 이름/후기 매칭으로 주택·부동산·일반 음식점 등 무관한 곳을 섞어
      // 내려주는데, 그것까지 전부 pet_cafe 로 라벨링되던 문제를 막는다.
      // 분류에 애견/애완/반려/펫 또는 '카페'가 들어간 곳만 남긴다.
      const cat = String(it?.category ?? "");
      const isPetPlace = /애견|애완|반려|펫/.test(cat);
      const isCafe = cat.includes("카페");
      if (!isPetPlace && !isCafe) return null;
      const coord = toWgs84(it.mapx, it.mapy);
      if (!coord) return null;
      return {
        category: "pet_cafe",
        name: stripTags(it.title),
        address: it.roadAddress || it.address || null,
        phone: it.telephone || null,
        lat: coord.lat,
        lng: coord.lng,
      };
    })
    .filter(Boolean);

  return json({ items });
});
