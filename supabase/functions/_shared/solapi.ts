// ============================================================================
// Solapi (구 CoolSMS) SMS 발송 클라이언트
// 인증: HMAC-SHA256 서명 헤더
//   signature = HMAC_SHA256(secret, date + salt) (hex)
//   Authorization: HMAC-SHA256 apiKey=..., date=..., salt=..., signature=...
// 발송: POST https://api.solapi.com/messages/v4/send
//   body: { message: { to, from, text } }
// 발신번호(from)는 Solapi 콘솔에 사전등록된 번호여야 한다(국내 규정).
// ============================================================================

const SOLAPI_BASE = "https://api.solapi.com";

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function hmacSha256Hex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(data),
  );
  return hex(sig);
}

function randomSalt(length = 32): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return hex(bytes.buffer).slice(0, length);
}

async function authHeader(
  apiKey: string,
  apiSecret: string,
): Promise<string> {
  const date = new Date().toISOString();
  const salt = randomSalt();
  const signature = await hmacSha256Hex(apiSecret, date + salt);
  return `HMAC-SHA256 apiKey=${apiKey}, date=${date}, salt=${salt}, signature=${signature}`;
}

// 국내 휴대폰 번호 정규화: 숫자만 남기고 +82/82 → 0 으로 변환 (예: +821012345678 → 01012345678)
export function normalizePhone(raw: string): string {
  let digits = (raw ?? "").replace(/[^\d]/g, "");
  if (digits.startsWith("82")) digits = "0" + digits.slice(2);
  return digits;
}

export interface SolapiConfig {
  apiKey: string;
  apiSecret: string;
  from: string;
}

export function loadSolapiConfig(): SolapiConfig {
  const apiKey = Deno.env.get("SOLAPI_API_KEY");
  const apiSecret = Deno.env.get("SOLAPI_API_SECRET");
  const from = Deno.env.get("SOLAPI_SENDER");
  if (!apiKey || !apiSecret || !from) {
    throw new Error(
      "Solapi 환경변수 누락: SOLAPI_API_KEY / SOLAPI_API_SECRET / SOLAPI_SENDER 를 설정하세요.",
    );
  }
  return { apiKey, apiSecret, from };
}

export async function sendSms(
  cfg: SolapiConfig,
  to: string,
  text: string,
): Promise<{ ok: boolean; status: number; body: unknown }> {
  const Authorization = await authHeader(cfg.apiKey, cfg.apiSecret);
  const res = await fetch(`${SOLAPI_BASE}/messages/v4/send`, {
    method: "POST",
    headers: { Authorization, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: { to: normalizePhone(to), from: normalizePhone(cfg.from), text },
    }),
  });
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    body = await res.text();
  }
  return { ok: res.ok, status: res.status, body };
}
