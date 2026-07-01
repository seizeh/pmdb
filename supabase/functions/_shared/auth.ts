// 공용 인증 유틸 — 커스텀 HS256 JWT 서명/검증, sha256, 랜덤 refresh 토큰.
// 서명키는 각 함수 시크릿 JWT_SECRET(Supabase JWT Secret). access 는 PostgREST 네이티브 검증.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

function bytesToB64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function strToB64url(s: string): string {
  return bytesToB64url(new TextEncoder().encode(s));
}
function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function hmacKey(secret: string, usage: KeyUsage[]): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, usage);
}

/// access JWT 서명(HS256). role/aud=authenticated, iss=supabase, tv 클레임 포함.
export async function signAccess(
  sub: string, tv: number, ttlSec: number, secret: string,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = strToB64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = strToB64url(JSON.stringify({
    sub, role: "authenticated", aud: "authenticated", iss: "supabase",
    iat: now, exp: now + ttlSec, tv,
  }));
  const data = `${header}.${payload}`;
  const key = await hmacKey(secret, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return `${data}.${bytesToB64url(new Uint8Array(sig))}`;
}

/// access JWT 검증 → 클레임(만료/서명 확인). 실패 시 null.
export async function verifyAccess(
  token: string, secret: string,
): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  // alg 헤더 고정 확인(방어적 — alg-confusion/none 차단, 현재도 HMAC 고정이라 무해).
  try {
    if (JSON.parse(new TextDecoder().decode(b64urlToBytes(h))).alg !== "HS256") return null;
  } catch {
    return null;
  }
  const key = await hmacKey(secret, ["verify"]);
  const ok = await crypto.subtle.verify(
    "HMAC", key, b64urlToBytes(s), new TextEncoder().encode(`${h}.${p}`));
  if (!ok) return null;
  try {
    const claims = JSON.parse(new TextDecoder().decode(b64urlToBytes(p)));
    if (typeof claims.exp === "number" && claims.exp < Math.floor(Date.now() / 1000)) {
      return null;
    }
    return claims;
  } catch {
    return null;
  }
}

export function bearer(req: Request): string | null {
  const m = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : null;
}

/// refresh_tokens.user_agent 저장용 — 300자로 절단(저장 비대화/남용 방지). 없으면 null.
export function clientUa(req: Request): string | null {
  const ua = req.headers.get("user-agent");
  return ua ? ua.slice(0, 300) : null;
}

/// 레이트리밋 키용 클라이언트 IP. 신뢰 프록시가 설정하는 헤더(cf-connecting-ip/x-real-ip)
/// 우선 — x-forwarded-for leftmost 는 클라가 주입 가능(스푸핑 가능)이라 최후 폴백.
/// 식별 불가 시 null → 호출부는 IP 버킷을 건너뛴다(전역 'unknown' 버킷 오작동 방지).
/// ⚠ IP 제한은 보조 방어선일 뿐(스푸핑 가능). 1차 방어는 스푸핑 불가한 토큰해시·계정 버킷.
export function clientIp(req: Request): string | null {
  const trusted = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip");
  if (trusted) return trusted.trim();
  const xff = req.headers.get("x-forwarded-for");
  return xff ? (xff.split(",")[0].trim() || null) : null;
}

/// 레이트리밋 1회 소모. true=제한 초과(차단해야 함), false=허용.
/// 리미터 자체 오류는 fail-open(가용성 우선 — 로그인/갱신을 막지 않음).
// deno-lint-ignore no-explicit-any
export async function rateLimited(
  supabase: any, key: string, max: number, windowSeconds: number,
): Promise<boolean> {
  const { data, error } = await supabase.rpc("rate_limit_hit", {
    p_key: key, p_max: max, p_window_seconds: windowSeconds,
  });
  if (error) {
    console.error("rate_limit_hit failed", error);
    return false;
  }
  return data === false;
}

/// refresh 토큰의 저장용 해시(원문은 저장 금지).
export async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// 불투명 refresh 토큰 원문(256bit).
export function randomToken(bytes = 32): string {
  const b = new Uint8Array(bytes);
  crypto.getRandomValues(b);
  return bytesToB64url(b);
}

export const ACCESS_TTL_CAPABLE = 60 * 60 * 8; // 8h (refresh 지원 클라)
export const ACCESS_TTL_LEGACY = 60 * 60 * 24 * 30; // 30d (레거시, 추후 축소)
export const REFRESH_GRACE_SECONDS = 30;
