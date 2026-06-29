// ============================================================================
// resolve-region — 좌표 → 행정동(코드/이름) 역지오코딩 (부수효과 없음) (0021)
//   POST { lat, lng }   Authorization: Bearer <login JWT>
//   → { regionCode, regionName, address }  (실패 시 { regionCode: null })
//
//   게시글 작성 시 "현재 위치가 인증 동네와 다른지" 안내용. DB 변경/인증기록 없음.
//   --no-verify-jwt 배포 + JWT 수동 검증. 키는 서버 시크릿(NCP Maps).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

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

  const uid = await getUidFromJwt(req, JWT_SECRET);
  if (!uid) return json({ error: "unauthorized" }, 401);

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
