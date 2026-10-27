// ============================================================================
// attest-register — iOS App Attest 키 등록 (보안설계 v9.2 §7.5)
//
//   POST { phase: "challenge" }                          → { challenge }  (base64 32B)
//   POST { phase: "register", keyId, attestation }        → { registered, env }
//        Authorization: Bearer <login JWT>
//
// 앱 설치당 1회: DCAppAttestService.generateKey → attestKey(keyId,
// SHA256(challenge)) 의 증명 오브젝트를 서버가 Apple 루트 CA 체인으로 검증하고
// 공개키를 등록한다(app.device_attest_keys). 이후 verify-location /
// verify-post-photo 요청의 assertion 을 이 공개키로 검증한다(현재 섀도).
//
// Android(Play Integrity)는 무상태라 등록이 없다 — 이 함수는 iOS 전용.
// 챌린지는 등록 증명의 재전송 방지용 1회성 값(TTL 5분, attest_challenge_take 가
// 원자적으로 소진). 검증 실패는 클라이언트 귀책이라 400 — 서버 알람 없음.
// ============================================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, withCors } from "../_shared/cors.ts";
import { activeUid, rateLimited } from "../_shared/auth.ts";
import { bytesToB64, verifyAppAttestAttestation } from "../_shared/attest.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JWT_SECRET = Deno.env.get("JWT_SECRET");

// 체인 검증은 로컬 연산이지만 파싱·서명 검증 비용이 있다 — 재설치·재시도 감안 시간당 10.
const REG_MAX = 10;
const REG_WINDOW_SEC = 3600;

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!JWT_SECRET) {
    console.error("JWT_SECRET 미설정");
    return json({ error: "server_misconfigured" }, 500);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
  const uid = await activeUid(req, JWT_SECRET, admin);
  if (!uid) return json({ error: "unauthorized" }, 401);

  if (await rateLimited(admin, `attestreg:${uid}`, REG_MAX, REG_WINDOW_SEC)) {
    return json({ error: "rate_limited" }, 429);
  }

  let p: { phase?: string; keyId?: string; attestation?: string };
  try {
    p = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (p.phase === "challenge") {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    const challenge = bytesToB64(bytes);
    const { error } = await admin.rpc("attest_challenge_put", {
      p_user: uid, p_challenge_b64: challenge,
    });
    if (error) {
      console.error("attest_challenge_put failed", error);
      return json({ error: "internal_error" }, 500);
    }
    return json({ challenge });
  }

  if (p.phase === "register") {
    const keyId = typeof p.keyId === "string" ? p.keyId : "";
    const attestation = typeof p.attestation === "string" ? p.attestation : "";
    if (!keyId || !attestation) return json({ error: "missing_fields" }, 400);

    const { data: challenge, error: takeErr } = await admin.rpc("attest_challenge_take", {
      p_user: uid,
    });
    if (takeErr) {
      console.error("attest_challenge_take failed", takeErr);
      return json({ error: "internal_error" }, 500);
    }
    if (typeof challenge !== "string" || !challenge) {
      return json({ error: "challenge_expired" }, 400);
    }

    const r = await verifyAppAttestAttestation(
      attestation, keyId, Uint8Array.from(atob(challenge), (c) => c.charCodeAt(0)));
    if (!r.ok) return json({ error: "attest_invalid", reason: r.reason }, 400);

    const { error: regErr } = await admin.rpc("attest_key_register", {
      p_user: uid, p_key_id: keyId, p_spki_b64: r.spkiB64,
    });
    if (regErr) {
      console.error("attest_key_register failed", regErr);
      return json({ error: "internal_error" }, 500);
    }
    return json({ registered: true, env: r.env });
  }

  return json({ error: "bad_phase" }, 400);
}));
