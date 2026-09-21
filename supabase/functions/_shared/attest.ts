// ============================================================================
// 기기 증명(App Attest / Play Integrity) 검증 — 보안설계 v9.2 §7.5
//
// 좌표 자기신고(lat/lng/accuracy/isMocked)의 보강: "미변조 정품 앱이 정품 기기에서
// 보낸 요청"인지를 검증한다. **좌표의 참을 증명하지는 못한다** — 직접 POST 위조·
// 에뮬레이터·리패키징 벡터를 없애는 비용 상승 장치다(정품 기기의 모의위치 앱은
// 여전히 isMocked 가 담당).
//
// 핵심은 **요청 본문 바인딩**: 증명의 clientDataHash(iOS)/requestHash(Android)에
// 요청 본문 SHA-256 을 넣어, 증명은 정상 앱으로 받고 좌표만 바꿔 보내는 재조합을
// 막는다. 재사용은 iOS 는 sign_count 단조 증가가, Android 는 토큰 타임스탬프
// 신선도(≤5분)가 막는다.
//
// 검증 구현은 이 모듈 **한 벌**뿐이다 — JWT 검증 사본 6벌이 드리프트로 뚫렸던 전례
// (0032 §4.1, activeUid 통일)의 재발 방지. 외부 의존성 없이 WebCrypto 로만 구현한다
// (CBOR·DER 파서 포함) — 공급망 표면을 늘리지 않기 위해서다(§10.2 공급망 항목).
//
// 현재는 **섀도 모드**: attestShadow() 가 판정을 app.attest_checks 에 기록만 하고
// 절대 거절하지 않는다(측정 전 하드 리젝 금지 — frames_from_video 관례). 강제 전환은
// ATTEST_ENFORCE 상수(코드 수정 PR + 배포, 구클라 강제 업데이트 이후 — 0025 §1.7).
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// 강제 전환 스위치 — 섀도 측정(app.attest_checks 의 fail 비율·absent 비율) 확인 전에
// true 로 바꾸지 말 것. 전환 시 attest_required/attest_failed 응답 코드의 앱 문구
// 매핑을 같은 PR 에서 넣는다(§10.2 "새 응답 코드 앱 매핑 0건" 재발 방지).
export const ATTEST_ENFORCE = false;

// env 는 지연 접근 — CI 의 `deno test`(권한 플래그 없음)에서 모듈 로드가 터지지 않게.
function envOr(name: string, fallback: string): string {
  try {
    return Deno.env.get(name) ?? fallback;
  } catch {
    return fallback;
  }
}
// App ID = <TeamID>.<BundleID>. 시크릿으로 덮을 수 있으나 기본값이 운영값이다.
const iosAppId = () => envOr("ATTEST_IOS_APP_ID", "5GVP46ZJ2H.com.seizeh.pawmate");
const androidPackage = () => envOr("ATTEST_ANDROID_PACKAGE", "com.seizeh.pawmate");
// Play Integrity 복호용 서비스 계정(JSON: client_email, private_key).
// 미설정이면 Android 판정은 'skip'(섀도 측정에는 잡힌다) — iOS 는 시크릿이 필요 없다.
const playSaJson = () => envOr("PLAY_INTEGRITY_SA_JSON", "");
// Play 서명 인증서 SHA-256 digest 허용 목록(base64url, 콤마 구분). 미설정이면 생략
// (Play App Signing 키 digest 확인 전까지 — 패키지명·verdict 검사는 항상 한다).
const playCertDigests = () =>
  envOr("PLAY_CERT_SHA256_DIGESTS", "").split(",").map((s) => s.trim()).filter(Boolean);

const PLAY_TOKEN_MAX_AGE_MS = 5 * 60 * 1000;

// Apple App Attestation Root CA — https://www.apple.com/certificateauthority/
// (SHA-256 지문 1CB9823B…42C932, 2026-09-21 공식 배포본 확인)
const APPLE_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

// ── 바이트 유틸 ─────────────────────────────────────────────────────────────

export function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

export function bytesToB64url(bytes: Uint8Array): string {
  return bytesToB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function bytesEq(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
}

function pemToDer(pem: string): Uint8Array {
  return b64ToBytes(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
}

// ── CBOR 디코더 (App Attest 오브젝트가 쓰는 부분집합: 정길이 uint/bytes/text/array/map) ──

export function decodeCbor(bytes: Uint8Array): unknown {
  const [v, off] = readCbor(bytes, 0);
  if (off !== bytes.length) throw new Error("cbor: trailing bytes");
  return v;
}

function readCbor(b: Uint8Array, off: number): [unknown, number] {
  if (off >= b.length) throw new Error("cbor: eof");
  const ib = b[off];
  const major = ib >> 5;
  const info = ib & 0x1f;
  let n: number;
  let p = off + 1;
  if (info < 24) n = info;
  else if (info === 24) [n, p] = [b[p], p + 1];
  else if (info === 25) [n, p] = [(b[p] << 8) | b[p + 1], p + 2];
  else if (info === 26) {
    n = b[p] * 0x1000000 + ((b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]);
    p += 4;
  } else throw new Error("cbor: unsupported length");
  switch (major) {
    case 0: return [n, p];
    case 1: return [-1 - n, p];
    case 2: {
      if (p + n > b.length) throw new Error("cbor: bytes eof");
      return [b.slice(p, p + n), p + n];
    }
    case 3: {
      if (p + n > b.length) throw new Error("cbor: text eof");
      return [new TextDecoder().decode(b.slice(p, p + n)), p + n];
    }
    case 4: {
      const arr: unknown[] = [];
      for (let i = 0; i < n; i++) {
        const [v, np] = readCbor(b, p);
        arr.push(v);
        p = np;
      }
      return [arr, p];
    }
    case 5: {
      const obj: Record<string, unknown> = {};
      for (let i = 0; i < n; i++) {
        const [k, kp] = readCbor(b, p);
        const [v, vp] = readCbor(b, kp);
        obj[String(k)] = v;
        p = vp;
      }
      return [obj, p];
    }
    default:
      throw new Error(`cbor: unsupported major ${major}`);
  }
}

// ── DER 파서 (X.509 인증서에서 검증에 필요한 조각만) ────────────────────────

type Tlv = { tag: number; start: number; content: number; end: number };

function readTlv(b: Uint8Array, off: number): Tlv {
  if (off + 2 > b.length) throw new Error("der: eof");
  const tag = b[off];
  let len = b[off + 1];
  let p = off + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4 || p + n > b.length) throw new Error("der: bad length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[p + i];
    p += n;
  }
  if (p + len > b.length) throw new Error("der: content eof");
  return { tag, start: off, content: p, end: p + len };
}

function children(b: Uint8Array, tlv: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let p = tlv.content;
  while (p < tlv.end) {
    const c = readTlv(b, p);
    out.push(c);
    p = c.end;
  }
  return out;
}

function oidToString(b: Uint8Array, tlv: Tlv): string {
  const bytes = b.slice(tlv.content, tlv.end);
  const parts: number[] = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let acc = 0;
  for (let i = 1; i < bytes.length; i++) {
    acc = acc * 128 + (bytes[i] & 0x7f);
    if (!(bytes[i] & 0x80)) {
      parts.push(acc);
      acc = 0;
    }
  }
  return parts.join(".");
}

function parseTime(b: Uint8Array, tlv: Tlv): Date {
  const s = new TextDecoder().decode(b.slice(tlv.content, tlv.end));
  // UTCTime(YYMMDDHHMMSSZ) / GeneralizedTime(YYYYMMDDHHMMSSZ)
  const full = tlv.tag === 0x18 ? s : (Number(s.slice(0, 2)) >= 50 ? "19" + s : "20" + s);
  const m = full.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
  if (!m) throw new Error("der: bad time");
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
}

export type ParsedCert = {
  tbs: Uint8Array; // 서명 대상 원문(TLV 전체)
  sigAlgOid: string;
  signature: Uint8Array; // BIT STRING 내용(DER ECDSA-Sig)
  spki: Uint8Array; // SubjectPublicKeyInfo TLV 전체(importKey 'spki' 용)
  curveOid: string | null;
  publicKeyPoint: Uint8Array; // BIT STRING 내용(비압축 EC 포인트)
  notBefore: Date;
  notAfter: Date;
  extensions: Map<string, Uint8Array>; // extnID → extnValue(OCTET STRING 내용)
};

export function parseCertificate(der: Uint8Array): ParsedCert {
  const cert = readTlv(der, 0);
  const [tbsTlv, sigAlgTlv, sigTlv] = children(der, cert);
  const tbs = der.slice(tbsTlv.start, tbsTlv.end);
  const sigAlgOid = oidToString(der, children(der, sigAlgTlv)[0]);
  const signature = der.slice(sigTlv.content + 1, sigTlv.end); // 선두 unused-bits 바이트 제거

  const tbsKids = children(der, tbsTlv);
  let i = 0;
  if (tbsKids[0].tag === 0xa0) i = 1; // [0] version
  // serial(i) sigAlg(i+1) issuer(i+2) validity(i+3) subject(i+4) spki(i+5)
  const validity = children(der, tbsKids[i + 3]);
  const notBefore = parseTime(der, validity[0]);
  const notAfter = parseTime(der, validity[1]);
  const spkiTlv = tbsKids[i + 5];
  const spki = der.slice(spkiTlv.start, spkiTlv.end);
  const spkiKids = children(der, spkiTlv);
  const algKids = children(der, spkiKids[0]);
  const curveOid = algKids.length > 1 && algKids[1].tag === 0x06
    ? oidToString(der, algKids[1])
    : null;
  const publicKeyPoint = der.slice(spkiKids[1].content + 1, spkiKids[1].end);

  const extensions = new Map<string, Uint8Array>();
  for (const k of tbsKids.slice(i + 6)) {
    if (k.tag !== 0xa3) continue; // [3] extensions
    const extSeq = children(der, k)[0];
    for (const ext of children(der, extSeq)) {
      const kids = children(der, ext);
      const oid = oidToString(der, kids[0]);
      const value = kids[kids.length - 1]; // (critical BOOLEAN 은 건너뜀)
      extensions.set(oid, der.slice(value.content, value.end));
    }
  }
  return { tbs, sigAlgOid, signature, spki, curveOid, publicKeyPoint, notBefore, notAfter, extensions };
}

// ECDSA DER 서명(SEQ{INT r, INT s}) → WebCrypto raw(r‖s, 고정폭).
export function derSigToRaw(der: Uint8Array, size: number): Uint8Array {
  const seq = readTlv(der, 0);
  const [rTlv, sTlv] = children(der, seq);
  const trim = (t: Tlv) => {
    let b = der.slice(t.content, t.end);
    while (b.length > 1 && b[0] === 0) b = b.slice(1);
    if (b.length > size) throw new Error("der: int too long");
    const out = new Uint8Array(size);
    out.set(b, size - b.length);
    return out;
  };
  return concat(trim(rTlv), trim(sTlv));
}

const CURVES: Record<string, { name: string; size: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
};
const SIG_HASHES: Record<string, string> = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
  "1.2.840.10045.4.3.4": "SHA-512",
};

async function importSpki(spki: Uint8Array, curveOid: string | null): Promise<CryptoKey> {
  const curve = curveOid ? CURVES[curveOid] : undefined;
  if (!curve) throw new Error(`unsupported curve ${curveOid}`);
  return await crypto.subtle.importKey(
    "spki", spki as BufferSource, { name: "ECDSA", namedCurve: curve.name }, false, ["verify"]);
}

// cert 가 issuer(SPKI) 로 서명됐는지.
export async function certSignedBy(cert: ParsedCert, issuer: ParsedCert): Promise<boolean> {
  const hash = SIG_HASHES[cert.sigAlgOid];
  const curve = issuer.curveOid ? CURVES[issuer.curveOid] : undefined;
  if (!hash || !curve) return false;
  const key = await importSpki(issuer.spki, issuer.curveOid);
  const raw = derSigToRaw(cert.signature, curve.size);
  return await crypto.subtle.verify(
    { name: "ECDSA", hash }, key, raw as BufferSource, cert.tbs as BufferSource);
}

// leaf ← intermediate ← root(고정) 체인 + 유효기간. root 는 SPKI 동일성으로 고정.
export async function verifyChainToAppleRoot(
  leaf: ParsedCert, intermediate: ParsedCert, rootPem = APPLE_ROOT_PEM,
): Promise<boolean> {
  const root = parseCertificate(pemToDer(rootPem));
  const now = new Date();
  for (const c of [leaf, intermediate, root]) {
    if (now < c.notBefore || now > c.notAfter) return false;
  }
  if (!(await certSignedBy(leaf, intermediate))) return false;
  if (!(await certSignedBy(intermediate, root))) return false;
  return true;
}

// ── App Attest ──────────────────────────────────────────────────────────────

const APPLE_NONCE_OID = "1.2.840.113635.100.8.2";

function u32be(b: Uint8Array, off: number): number {
  return b[off] * 0x1000000 + ((b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]);
}

export type AttestationResult =
  | { ok: true; spkiB64: string; env: "production" | "development" }
  | { ok: false; reason: string };

/// 등록(attestKey) 검증 — Apple 문서의 검증 절차 그대로.
/// challenge 는 서버가 발급한 1회성 값(attest-register 가 관리).
export async function verifyAppAttestAttestation(
  attestationB64: string, keyIdB64: string, challenge: Uint8Array, appId?: string,
  rootPem = APPLE_ROOT_PEM,
): Promise<AttestationResult> {
  appId = appId ?? iosAppId();
  try {
    const obj = decodeCbor(b64ToBytes(attestationB64)) as Record<string, unknown>;
    if (obj.fmt !== "apple-appattest") return { ok: false, reason: "bad_fmt" };
    const attStmt = obj.attStmt as Record<string, unknown>;
    const x5c = attStmt?.x5c as Uint8Array[] | undefined;
    const authData = obj.authData as Uint8Array | undefined;
    if (!Array.isArray(x5c) || x5c.length < 2 || !(authData instanceof Uint8Array)) {
      return { ok: false, reason: "bad_shape" };
    }
    const leaf = parseCertificate(x5c[0]);
    const intermediate = parseCertificate(x5c[1]);
    if (!(await verifyChainToAppleRoot(leaf, intermediate, rootPem))) {
      return { ok: false, reason: "bad_chain" };
    }
    // nonce = SHA256(authData ‖ SHA256(challenge)) 가 leaf 인증서 확장에 있어야 한다.
    const clientDataHash = await sha256(challenge);
    const expectedNonce = await sha256(concat(authData, clientDataHash));
    const ext = leaf.extensions.get(APPLE_NONCE_OID);
    if (!ext) return { ok: false, reason: "no_nonce_ext" };
    // 확장 내용: SEQ { [1] { OCTET STRING nonce } }
    const seq = readTlv(ext, 0);
    const ctx = children(ext, seq)[0];
    const oct = readTlv(ext, ctx.content);
    const nonce = ext.slice(oct.content, oct.end);
    if (!bytesEq(nonce, expectedNonce)) return { ok: false, reason: "nonce_mismatch" };
    // keyId == SHA256(공개키 포인트)
    const keyId = b64ToBytes(keyIdB64);
    if (!bytesEq(await sha256(leaf.publicKeyPoint), keyId)) {
      return { ok: false, reason: "keyid_mismatch" };
    }
    // authData: rpIdHash(32) flags(1) signCount(4) aaguid(16) credIdLen(2) credId
    if (authData.length < 55) return { ok: false, reason: "authdata_short" };
    const rpIdHash = authData.slice(0, 32);
    if (!bytesEq(rpIdHash, await sha256(appId))) return { ok: false, reason: "rpid_mismatch" };
    if (u32be(authData, 33) !== 0) return { ok: false, reason: "counter_not_zero" };
    const aaguid = new TextDecoder().decode(authData.slice(37, 53)).replace(/\0+$/, "");
    if (aaguid !== "appattest" && aaguid !== "appattestdevelop") {
      return { ok: false, reason: "bad_aaguid" };
    }
    const credIdLen = (authData[53] << 8) | authData[54];
    const credId = authData.slice(55, 55 + credIdLen);
    if (!bytesEq(credId, keyId)) return { ok: false, reason: "credid_mismatch" };
    return {
      ok: true,
      spkiB64: bytesToB64(leaf.spki),
      env: aaguid === "appattest" ? "production" : "development",
    };
  } catch (e) {
    return { ok: false, reason: `parse_error:${e instanceof Error ? e.message : String(e)}` };
  }
}

export type AssertionResult =
  | { ok: true; signCount: number }
  | { ok: false; reason: string };

/// 요청별 assertion 검증 — clientDataHash = SHA256(요청 본문 원문).
export async function verifyAppAttestAssertion(
  assertionB64: string, clientDataHash: Uint8Array, spkiB64: string,
  prevSignCount: number, appId?: string,
): Promise<AssertionResult> {
  appId = appId ?? iosAppId();
  try {
    const obj = decodeCbor(b64ToBytes(assertionB64)) as Record<string, unknown>;
    const sig = obj.signature as Uint8Array | undefined;
    const authData = obj.authenticatorData as Uint8Array | undefined;
    if (!(sig instanceof Uint8Array) || !(authData instanceof Uint8Array) || authData.length < 37) {
      return { ok: false, reason: "bad_shape" };
    }
    if (!bytesEq(authData.slice(0, 32), await sha256(appId))) {
      return { ok: false, reason: "rpid_mismatch" };
    }
    const signCount = u32be(authData, 33);
    if (signCount <= prevSignCount) return { ok: false, reason: "counter_replay" };
    const nonce = await sha256(concat(authData, clientDataHash));
    const key = await crypto.subtle.importKey(
      "spki", b64ToBytes(spkiB64) as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, key,
      derSigToRaw(sig, 32) as BufferSource, nonce as BufferSource);
    return ok ? { ok: true, signCount } : { ok: false, reason: "bad_signature" };
  } catch (e) {
    return { ok: false, reason: `parse_error:${e instanceof Error ? e.message : String(e)}` };
  }
}

// ── Play Integrity ──────────────────────────────────────────────────────────

let _gToken: { token: string; exp: number } | null = null;

async function googleAccessToken(saJson: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_gToken && _gToken.exp - 60 > now) return _gToken.token;
  const sa = JSON.parse(saJson) as { client_email: string; private_key: string };
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/playintegrity",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const enc = (o: unknown) => bytesToB64url(new TextEncoder().encode(JSON.stringify(o)));
  const signingInput = `${enc(header)}.${enc(claims)}`;
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8", b64ToBytes(pem) as BufferSource,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput)));
  const assertion = `${signingInput}.${bytesToB64url(sig)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}` +
      `&assertion=${encodeURIComponent(assertion)}`,
  });
  if (!res.ok) throw new Error(`oauth ${res.status}`);
  const body = await res.json() as { access_token: string; expires_in: number };
  _gToken = { token: body.access_token, exp: now + (body.expires_in ?? 3600) };
  return _gToken.token;
}

export type PlayResult =
  | { ok: true; device: string[]; app: string }
  | { ok: false; reason: string };

/// Play Integrity 표준 토큰 복호·검증. expectedRequestHash = base64url(SHA256(본문)).
export async function verifyPlayIntegrityToken(
  token: string, expectedRequestHash: string, packageName?: string,
): Promise<PlayResult> {
  packageName = packageName ?? androidPackage();
  const saJson = playSaJson();
  if (!saJson) return { ok: false, reason: "skip_no_secret" };
  let res: Response;
  try {
    const access = await googleAccessToken(saJson);
    res = await fetch(
      `https://playintegrity.googleapis.com/v1/${encodeURIComponent(packageName)}:decodeIntegrityToken`,
      {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${access}` },
        body: JSON.stringify({ integrityToken: token }),
      },
    );
  } catch (e) {
    return { ok: false, reason: `decode_unavailable:${e instanceof Error ? e.message : "fetch"}` };
  }
  if (!res.ok) return { ok: false, reason: `decode_http_${res.status}` };
  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await res.json();
  } catch {
    return { ok: false, reason: "decode_bad_json" };
  }
  const p = body?.tokenPayloadExternal;
  const reqd = p?.requestDetails;
  if (!reqd) return { ok: false, reason: "no_request_details" };
  if (reqd.requestPackageName !== packageName) return { ok: false, reason: "package_mismatch" };
  if ((reqd.requestHash ?? "") !== expectedRequestHash) return { ok: false, reason: "hash_mismatch" };
  const ts = Number(reqd.timestampMillis ?? 0);
  if (!ts || Math.abs(Date.now() - ts) > PLAY_TOKEN_MAX_AGE_MS) {
    return { ok: false, reason: "stale_token" };
  }
  const app = p?.appIntegrity;
  if (app?.appRecognitionVerdict !== "PLAY_RECOGNIZED") {
    return { ok: false, reason: `app_${app?.appRecognitionVerdict ?? "missing"}` };
  }
  if (app?.packageName !== packageName) return { ok: false, reason: "app_package_mismatch" };
  const certDigests = playCertDigests();
  if (certDigests.length > 0) {
    const digests: string[] = app?.certificateSha256Digest ?? [];
    if (!digests.some((d) => certDigests.includes(d))) {
      return { ok: false, reason: "cert_digest_mismatch" };
    }
  }
  const device: string[] = p?.deviceIntegrity?.deviceRecognitionVerdict ?? [];
  if (!device.includes("MEETS_DEVICE_INTEGRITY")) {
    return { ok: false, reason: `device_${device.join("|") || "missing"}` };
  }
  return { ok: true, device, app: app.appRecognitionVerdict };
}

// ── 섀도 진입점 — verify-location / verify-post-photo 가 부른다 ─────────────

/// 헤더에서 증명을 읽어 검증하고 app.attest_checks 에 기록한다. **절대 던지지 않고,
/// 절대 거절하지 않는다**(섀도). 강제 전환 후에도 이 함수는 판정만 하고 거절은
/// 호출부가 ATTEST_ENFORCE 로 한다.
// deno-lint-ignore no-explicit-any
export async function attestShadow(
  admin: any, req: Request, fn: string, uid: string, bodyText: string,
): Promise<void> {
  let platform = "none";
  let verdict = "absent";
  let reason: string | null = null;
  try {
    const h = req.headers.get("x-attest-platform");
    if (h === "ios") {
      platform = "ios";
      const keyId = req.headers.get("x-attest-key-id") ?? "";
      const assertion = req.headers.get("x-attest-assertion") ?? "";
      if (!keyId || !assertion) {
        verdict = "fail";
        reason = "missing_headers";
      } else {
        const { data, error } = await admin.rpc("attest_key_get", {
          p_user: uid, p_key_id: keyId,
        });
        const row = Array.isArray(data) ? data[0] : data;
        if (error || !row) {
          verdict = "fail";
          reason = "unknown_key";
        } else {
          const clientDataHash = await sha256(bodyText);
          const r = await verifyAppAttestAssertion(
            assertion, clientDataHash, row.spki_b64, Number(row.sign_count ?? 0));
          if (r.ok) {
            verdict = "pass";
            await admin.rpc("attest_key_bump", {
              p_user: uid, p_key_id: keyId, p_count: r.signCount,
            });
          } else {
            verdict = "fail";
            reason = r.reason;
          }
        }
      }
    } else if (h === "android") {
      platform = "android";
      const token = req.headers.get("x-attest-token") ?? "";
      if (!token) {
        verdict = "fail";
        reason = "missing_headers";
      } else {
        const expected = bytesToB64url(await sha256(bodyText));
        const r = await verifyPlayIntegrityToken(token, expected);
        if (r.ok) verdict = "pass";
        else if (r.reason === "skip_no_secret") {
          verdict = "skip";
          reason = r.reason;
        } else {
          verdict = "fail";
          reason = r.reason;
        }
      }
    } else if (h) {
      platform = h.slice(0, 20);
      verdict = "fail";
      reason = "bad_platform";
    }
  } catch (e) {
    verdict = "fail";
    reason = `shadow_error:${e instanceof Error ? e.message : String(e)}`;
  }
  try {
    const { error } = await admin.rpc("attest_check_log", {
      p_user: uid, p_fn: fn, p_platform: platform, p_verdict: verdict, p_reason: reason,
    });
    if (error) console.error("attest_check_log failed", error);
  } catch (e) {
    console.error("attest_check_log failed", e);
  }
}

/// 응답 지연 없이 섀도 판정을 백그라운드로 돌린다(EdgeRuntime.waitUntil).
// deno-lint-ignore no-explicit-any
export function attestShadowBg(
  admin: any, req: Request, fn: string, uid: string, bodyText: string,
): void {
  const p = attestShadow(admin, req, fn, uid, bodyText)
    .catch((e) => console.error("attest shadow failed", e));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p);
}
