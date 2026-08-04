// ============================================================================
// resolve-region — 좌표 → 행정동(코드/이름) 역지오코딩 (부수효과 없음) (0021)
//   POST { lat, lng }   Authorization: Bearer <login JWT>
//   → { regionCode, regionName, address }  (실패 시 { regionCode: null })
//
//   게시글 작성 시 "현재 위치가 인증 동네와 다른지" 안내용. DB 변경/인증기록 없음.
//   --no-verify-jwt 배포 + JWT 수동 검증. 키는 서버 시크릿(NCP Maps).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { activeUid, rateLimited } from "../_shared/auth.ts";

const JWT_SECRET = Deno.env.get("JWT_SECRET");
const NAVER_KEY_ID = Deno.env.get("NAVER_MAP_KEY_ID");
const NAVER_KEY = Deno.env.get("NAVER_MAP_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 유료 API(네이버 역지오코딩) 호출 상한 — 사용자당. 게시글 작성 화면에서 현재
// 위치를 확인할 때 부르므로 정상 사용은 시간당 몇 번이다. 루프 호출만 잡는다.
const GEO_MAX = 60;
const GEO_WINDOW_SEC = 3600;

async function reverseGeocode(lng: number, lat: number) {
  const url = "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc" +
    `?coords=${lng},${lat}&output=json&orders=admcode,legalcode,addr`;
  try {
    const res = await fetch(url, {
      headers: { "x-ncp-apigw-api-key-id": NAVER_KEY_ID!, "x-ncp-apigw-api-key": NAVER_KEY! },
    });
    if (!res.ok) return null;
    const body = await res.json();
    if (body?.status?.code !== 0 || !Array.isArray(body.results)) return null;
    const adm = body.results.find((r: any) => r.name === "admcode");
    const a1 = adm?.region?.area1?.name ?? "";
    const a2 = adm?.region?.area2?.name ?? "";
    const a3 = adm?.region?.area3?.name ?? "";
    if (!a3 || !adm?.code?.id) return null;
    return {
      regionCode: adm.code.id as string,
      regionName: a3 as string,
      address: [a1, a2, a3].filter(Boolean).join(" "),
    };
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET) return json({ error: "server_misconfigured" }, 500);
  if (!NAVER_KEY_ID || !NAVER_KEY) return json({ error: "server_misconfigured" }, 500);

  // 정지·회수·간이 토큰까지 걸러낸다(app.uid() 와 같은 판정) — service_role 로
  // 진행하므로 RLS 가 받아 주지 않는다.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
  const uid = await activeUid(req, JWT_SECRET, admin);
  if (!uid) return json({ error: "unauthorized" }, 401);

  // 유료 API 상한 — 호출 전에 소모한다(제한에 걸린 요청이 네이버로 나가지 않게).
  if (await rateLimited(admin, `georev:${uid}`, GEO_MAX, GEO_WINDOW_SEC)) {
    return json({ error: "rate_limited" }, 429);
  }

  let p: { lat?: number; lng?: number };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const lat = Number(p.lat), lng = Number(p.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return json({ error: "invalid_coords" }, 400);
  }
  const geo = await reverseGeocode(lng, lat);
  return json(geo ?? { regionCode: null, regionName: null, address: null });
});
