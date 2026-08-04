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
///
/// `extra` 는 권한 범위를 좁히는 클레임을 얹는 자리다. 현재 유일한 사용처는
/// signup-lite 의 `{ lite: true }` — DB 의 app.uid() 가 그 클레임을 보고 거부하고
/// app.uid_lite() 만 통과시킨다(20260803180000). **권한을 넓히는 용도로 쓰지 말 것**:
/// 이 클레임들은 서명 안에 들어가므로 클라이언트가 못 고치지만, 반대로 우리가 잘못
/// 넣으면 DB 쪽에서 되돌릴 방법이 토큰 만료뿐이다.
export async function signAccess(
  sub: string, tv: number, ttlSec: number, secret: string,
  extra?: Record<string, unknown>,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = strToB64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = strToB64url(JSON.stringify({
    sub, role: "authenticated", aud: "authenticated", iss: "supabase",
    iat: now, exp: now + ttlSec, tv, ...(extra ?? {}),
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

/// **service_role 로 진행하는 함수의 인증 관문** — DB 의 `app.uid()` 와 같은 판정을
/// Edge 쪽에서 재현한다. 통과하면 uid, 아니면 null(호출부는 401).
///
/// ── 왜 서명 검증만으로는 부족한가
/// access 토큰은 무상태다. 서명과 `exp` 만 보면 **정지된 계정과 회수된 토큰이
/// 수명 동안 그대로 통과한다**(refresh 지원 클라 8시간, 레거시 30일).
/// DB 경로는 `app.uid()` 가 매 요청 막지만, 자체 JWT 검증 후 service_role 로
/// 진행하는 함수들은 RLS 를 우회하므로 그 관문이 없다 — 관리자가 계정을
/// 정지시켜도 아무 일이 일어나지 않고, 그 사실이 어디에도 표시되지 않는다.
///
/// ── 무엇을 보는가 (app.uid() 와 동일)
///   status = 'active'      정지·탈퇴·간이 계정 차단 (즉시 반영)
///   token_version = tv     비밀번호 변경·재설정으로 회수된 토큰 차단
///   lite 클레임 없음        간이 후기 토큰 차단 — 이게 없으면 20260803180000 의
///                          방어가 **이 함수들에서만** 뚫린다(service_role 이라
///                          app.uid() 를 거치지 않는다)
///
/// ── 실패 시 fail-closed
/// 조회가 실패하면 null 이다. 레이트리밋(`rateLimited`)의 fail-open 과 반대인데,
/// 저쪽은 가용성 우선의 절충이고 이쪽은 **인증**이라 열어 둘 이유가 없다.
// deno-lint-ignore no-explicit-any
export async function activeUid(
  req: Request, secret: string, supabase: any,
): Promise<string | null> {
  const token = bearer(req);
  const claims = token ? await verifyAccess(token, secret) : null;
  const uid = typeof claims?.sub === "string" ? claims.sub : null;
  if (!uid) return null;
  // 텍스트 비교 — 예상 밖 값에서 캐스팅 오류로 터지지 않게(DB 쪽과 같은 이유).
  if (String(claims?.lite ?? "") === "true") return null;

  const tv = typeof claims?.tv === "number" ? claims.tv : 0;
  const { data, error } = await supabase
    .from("users").select("status, token_version").eq("id", uid).maybeSingle();
  if (error || !data) return null;
  if (data.status !== "active") return null;
  if ((data.token_version ?? 0) !== tv) return null;
  return uid;
}

/// refresh_tokens.user_agent 저장용 — 300자로 절단(저장 비대화/남용 방지). 없으면 null.
export function clientUa(req: Request): string | null {
  const ua = req.headers.get("user-agent");
  return ua ? ua.slice(0, 300) : null;
}

/// 레이트리밋 키용 클라이언트 IP — **`cf-connecting-ip` 하나만 쓴다.**
///
/// 이 값은 위조할 수 없다. 실측이다(ADR-0011 증상 4, 2026-08-01 운영 대상):
///
///   x-forwarded-for              통과 — 맨 왼쪽이 공격자 값
///   x-real-ip / sb-forwarded-for 무시됨(엣지가 걷어내고 실제 IP 유지)
///   cf-connecting-ip             **엣지가 요청 자체를 거부**(Cloudflare 1000)
///
/// Edge Function 경로도 같은지 2026-08-03 별도 확인했다 — 정상 요청은 함수에
/// 도달(400), `CF-Connecting-IP` 위조는 엣지에서 거부(1000), `cf-ray` 존재.
///
/// 그러므로 IP 버킷은 '보조선' 이 아니라 실제로 지켜지는 상한이다. 예전 주석은
/// 반대로 적혀 있었는데(“보조 방어선일 뿐 — 스푸핑 가능”), **재 보지 않고 쓴
/// 문장이었고 그 주석을 믿은 다른 판단까지 틀리게 만들었다**(0031 §3.7).
///
/// ⚠ **폴백을 두지 않는다.** 헤더가 없으면 null 이다 — 호출부는 IP 버킷을
/// 건너뛰고 스푸핑 불가한 1차 버킷(계정·토큰해시·전화번호)과 전역 상한이 받는다.
/// x-forwarded-for 로 폴백하면 그 폴백이 곧 우회로가 된다(헤더 하나 붙이면 매
/// 요청 다른 IP 가 되어 버킷이 무한히 갈린다). DB 경로가 같은 이유로 이미 폴백을
/// 지웠다 — `20260801140000_ratelimit_trusted_client_ip.sql`. 두 경로를 맞춘다.
export function clientIp(req: Request): string | null {
  const ip = req.headers.get("cf-connecting-ip");
  return ip ? (ip.trim() || null) : null;
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
