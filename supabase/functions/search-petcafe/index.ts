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
import { corsHeaders, json } from "../_shared/cors.ts";

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

function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
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
  const [h, p, s] = parts;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );
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

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

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
