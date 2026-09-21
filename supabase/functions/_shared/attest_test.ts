// 기기 증명 검증(_shared/attest.ts) 단위 테스트.
//
// App Attest 체인·증명은 openssl 로 합성한 픽스처(attest_fixtures.ts — 구조는 Apple
// 과 동일, 루트만 테스트 CA)로 검증한다. assertion 은 WebCrypto 로 실제 서명해
// 왕복 검증한다. Play Integrity 는 외부 API 호출이라 여기서 재지 않는다(요청 해시
// 대조·verdict 파싱은 운영 섀도 로그로 검증 — 보안설계 v9.2 §7.5).
import {
  b64ToBytes,
  bytesToB64,
  decodeCbor,
  derSigToRaw,
  parseCertificate,
  sha256,
  verifyAppAttestAssertion,
  verifyAppAttestAttestation,
  verifyChainToAppleRoot,
} from "./attest.ts";
import {
  FX_APP_ID,
  FX_AUTHDATA_B64,
  FX_CHALLENGE_B64,
  FX_INTER_DER_B64,
  FX_KEYID_B64,
  FX_LEAF_DER_B64,
  FX_ROOT_PEM,
} from "./attest_fixtures.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(`assert: ${msg}`);
}
function assertEq(a: unknown, b: unknown, msg: string) {
  if (a !== b) throw new Error(`assert: ${msg} — ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
}

// ── 테스트용 최소 CBOR 인코더(정길이) ───────────────────────────────────────
function cborHead(major: number, n: number): Uint8Array {
  if (n < 24) return new Uint8Array([(major << 5) | n]);
  if (n < 256) return new Uint8Array([(major << 5) | 24, n]);
  if (n < 65536) return new Uint8Array([(major << 5) | 25, n >> 8, n & 0xff]);
  return new Uint8Array([
    (major << 5) | 26, (n >>> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff,
  ]);
}
function cborConcat(...parts: Uint8Array<ArrayBufferLike>[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}
function encodeCbor(v: unknown): Uint8Array {
  if (typeof v === "number") return cborHead(0, v);
  if (typeof v === "string") {
    const b = new TextEncoder().encode(v);
    return cborConcat(cborHead(3, b.length), b);
  }
  if (v instanceof Uint8Array) return cborConcat(cborHead(2, v.length), v);
  if (Array.isArray(v)) {
    return cborConcat(cborHead(4, v.length), ...v.map(encodeCbor));
  }
  if (v && typeof v === "object") {
    const entries = Object.entries(v as Record<string, unknown>);
    return cborConcat(
      cborHead(5, entries.length),
      ...entries.flatMap(([k, val]) => [encodeCbor(k), encodeCbor(val)]),
    );
  }
  throw new Error("encodeCbor: unsupported");
}

// WebCrypto raw(r‖s) → DER(SEQ{INT,INT}) — Apple 이 보내는 형식 재현.
function rawSigToDer(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    let body: Uint8Array = b.slice(i);
    if (body[0] & 0x80) body = cborConcat(new Uint8Array([0]), body);
    return cborConcat(new Uint8Array([0x02, body.length]), body);
  };
  const r = int(raw.slice(0, raw.length / 2));
  const s = int(raw.slice(raw.length / 2));
  const seq = cborConcat(r, s);
  return cborConcat(new Uint8Array([0x30, seq.length]), seq);
}

function buildAttestation(overrides?: {
  fmt?: string;
  authData?: Uint8Array;
  x5c?: Uint8Array[];
}): string {
  const obj = {
    fmt: overrides?.fmt ?? "apple-appattest",
    attStmt: {
      x5c: overrides?.x5c ?? [b64ToBytes(FX_LEAF_DER_B64), b64ToBytes(FX_INTER_DER_B64)],
      receipt: new Uint8Array(0),
    },
    authData: overrides?.authData ?? b64ToBytes(FX_AUTHDATA_B64),
  };
  return bytesToB64(encodeCbor(obj));
}

Deno.test("cbor: 기본 타입 왕복", () => {
  const obj = {
    fmt: "apple-appattest",
    n: 42,
    bytes: new Uint8Array([1, 2, 3]),
    arr: ["a", new Uint8Array([9])],
  };
  const decoded = decodeCbor(encodeCbor(obj)) as Record<string, unknown>;
  assertEq(decoded.fmt, "apple-appattest", "text");
  assertEq(decoded.n, 42, "uint");
  assert(decoded.bytes instanceof Uint8Array && (decoded.bytes as Uint8Array)[2] === 3, "bytes");
  assert(Array.isArray(decoded.arr) && (decoded.arr as unknown[])[0] === "a", "array");
});

Deno.test("cbor: 잘린 입력은 예외", () => {
  let threw = false;
  try {
    decodeCbor(new Uint8Array([0x58, 0x20, 1, 2])); // bytes(32) 선언 후 2바이트
  } catch {
    threw = true;
  }
  assert(threw, "truncated cbor must throw");
});

Deno.test("derSigToRaw: 패딩·선행 0 처리", () => {
  // r=0x01, s=0x80(선행 0 포함 DER) → 각 32B 로 좌측 패딩
  const der = new Uint8Array([0x30, 0x08, 0x02, 0x01, 0x01, 0x02, 0x03, 0x00, 0x80, 0x01]);
  const raw = derSigToRaw(der, 32);
  assertEq(raw.length, 64, "size");
  assertEq(raw[31], 0x01, "r lsb");
  assertEq(raw[62], 0x80, "s byte");
  assertEq(raw[63], 0x01, "s lsb");
});

Deno.test("x509: 파싱 + 테스트 루트 체인 검증", async () => {
  const leaf = parseCertificate(b64ToBytes(FX_LEAF_DER_B64));
  const inter = parseCertificate(b64ToBytes(FX_INTER_DER_B64));
  assertEq(leaf.curveOid, "1.2.840.10045.3.1.7", "leaf P-256");
  assertEq(inter.curveOid, "1.3.132.0.34", "intermediate P-384");
  assertEq(leaf.publicKeyPoint.length, 65, "uncompressed point");
  assert(leaf.extensions.has("1.2.840.113635.100.8.2"), "nonce extension present");
  assert(await verifyChainToAppleRoot(leaf, inter, FX_ROOT_PEM), "chain to test root");
  // 진짜 Apple 루트(기본값)로는 실패해야 한다 — 루트 고정이 동작한다는 증거.
  assert(!(await verifyChainToAppleRoot(leaf, inter)), "must fail against real Apple root");
});

Deno.test("attestation: 정상 경로", async () => {
  const r = await verifyAppAttestAttestation(
    buildAttestation(), FX_KEYID_B64, b64ToBytes(FX_CHALLENGE_B64), FX_APP_ID, FX_ROOT_PEM);
  assert(r.ok, `expected ok, got ${JSON.stringify(r)}`);
  if (r.ok) {
    assertEq(r.env, "development", "aaguid appattestdevelop");
    assert(r.spkiB64.length > 0, "spki returned");
  }
});

Deno.test("attestation: 챌린지 불일치 → nonce_mismatch", async () => {
  const wrong = new Uint8Array(32).fill(7);
  const r = await verifyAppAttestAttestation(
    buildAttestation(), FX_KEYID_B64, wrong, FX_APP_ID, FX_ROOT_PEM);
  assert(!r.ok && r.reason === "nonce_mismatch", JSON.stringify(r));
});

Deno.test("attestation: keyId 불일치", async () => {
  const wrongKeyId = bytesToB64(new Uint8Array(32).fill(9));
  const r = await verifyAppAttestAttestation(
    buildAttestation(), wrongKeyId, b64ToBytes(FX_CHALLENGE_B64), FX_APP_ID, FX_ROOT_PEM);
  assert(!r.ok && r.reason === "keyid_mismatch", JSON.stringify(r));
});

Deno.test("attestation: authData 변조 → nonce_mismatch", async () => {
  const tampered = b64ToBytes(FX_AUTHDATA_B64);
  tampered[36] = 1; // signCount 변조 — nonce 가 어긋난다
  const r = await verifyAppAttestAttestation(
    buildAttestation({ authData: tampered }),
    FX_KEYID_B64, b64ToBytes(FX_CHALLENGE_B64), FX_APP_ID, FX_ROOT_PEM);
  assert(!r.ok && r.reason === "nonce_mismatch", JSON.stringify(r));
});

Deno.test("attestation: fmt 불일치", async () => {
  const r = await verifyAppAttestAttestation(
    buildAttestation({ fmt: "packed" }),
    FX_KEYID_B64, b64ToBytes(FX_CHALLENGE_B64), FX_APP_ID, FX_ROOT_PEM);
  assert(!r.ok && r.reason === "bad_fmt", JSON.stringify(r));
});

// ── assertion: WebCrypto 실서명 왕복 ────────────────────────────────────────

async function makeAssertion(appId: string, body: string, signCount: number) {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey));
  const rpIdHash = await sha256(appId);
  const authData = cborConcat(
    rpIdHash,
    new Uint8Array([0x40]),
    new Uint8Array([
      (signCount >>> 24) & 0xff, (signCount >> 16) & 0xff,
      (signCount >> 8) & 0xff, signCount & 0xff,
    ]),
  );
  const clientDataHash = await sha256(body);
  const nonce = await sha256(cborConcat(authData, clientDataHash));
  const rawSig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, pair.privateKey, nonce as BufferSource));
  const assertion = bytesToB64(encodeCbor({
    signature: rawSigToDer(rawSig),
    authenticatorData: authData,
  }));
  return { assertion, spkiB64: bytesToB64(spki), clientDataHash };
}

Deno.test("assertion: 정상 경로 + 카운터 전진", async () => {
  const appId = "TESTTEAM12.com.example.attest";
  const { assertion, spkiB64, clientDataHash } = await makeAssertion(appId, `{"lat":1}`, 3);
  const r = await verifyAppAttestAssertion(assertion, clientDataHash, spkiB64, 2, appId);
  assert(r.ok, JSON.stringify(r));
  if (r.ok) assertEq(r.signCount, 3, "counter");
});

Deno.test("assertion: 카운터 재사용 거절", async () => {
  const appId = "TESTTEAM12.com.example.attest";
  const { assertion, spkiB64, clientDataHash } = await makeAssertion(appId, `{"lat":1}`, 3);
  const r = await verifyAppAttestAssertion(assertion, clientDataHash, spkiB64, 3, appId);
  assert(!r.ok && r.reason === "counter_replay", JSON.stringify(r));
});

Deno.test("assertion: 본문 바꿔치기 → bad_signature", async () => {
  const appId = "TESTTEAM12.com.example.attest";
  const { assertion, spkiB64 } = await makeAssertion(appId, `{"lat":1}`, 3);
  const otherHash = await sha256(`{"lat":2}`); // 좌표만 바꾼 본문
  const r = await verifyAppAttestAssertion(assertion, otherHash, spkiB64, 2, appId);
  assert(!r.ok && r.reason === "bad_signature", JSON.stringify(r));
});

Deno.test("assertion: rpId 불일치", async () => {
  const appId = "TESTTEAM12.com.example.attest";
  const { assertion, spkiB64, clientDataHash } = await makeAssertion(appId, `{"lat":1}`, 3);
  const r = await verifyAppAttestAssertion(
    assertion, clientDataHash, spkiB64, 2, "OTHERTEAM0.com.example.other");
  assert(!r.ok && r.reason === "rpid_mismatch", JSON.stringify(r));
});
