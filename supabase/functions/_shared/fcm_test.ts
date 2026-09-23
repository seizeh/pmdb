// classifyFcmError — 오탐(살아 있는 토큰을 끄는 것)이 나지 않는가.
//
// 실행: deno test supabase/functions/_shared/fcm_test.ts
import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { classifyFcmError, summarizeFcmError } from "./fcm.ts";

/// 운영에서 실제로 받은 모양(2026-08-17·08-20). details[0] 은 언제나 상용구고
/// 진짜 사유는 details[1].reason 에 있다.
const apnsErr = (reason: string) => ({
  error: {
    status: "INVALID_ARGUMENT",
    message: "Request contains an invalid argument.",
    details: [
      { "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "INVALID_ARGUMENT" },
      { "@type": "type.googleapis.com/google.firebase.fcm.v1.ApnsError", reason },
    ],
  },
});

Deno.test("UNREGISTERED — 앱 삭제·만료. 확실한 죽은 토큰", () => {
  const v = classifyFcmError(
    { error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } },
    404,
  );
  assertEquals(v.tokenDead, true);
  assertEquals(v.needsAttention, false);
});

Deno.test("SENDER_ID_MISMATCH — 다른 프로젝트 토큰. 우리는 영원히 못 보낸다", () => {
  const v = classifyFcmError(
    { error: { status: "PERMISSION_DENIED", details: [{ errorCode: "SENDER_ID_MISMATCH" }] } },
    403,
  );
  assertEquals(v.tokenDead, true);
});

Deno.test("INVALID_ARGUMENT + 토큰 필드 지목 — 죽은 토큰이 맞다", () => {
  const v = classifyFcmError({
    error: {
      status: "INVALID_ARGUMENT",
      details: [
        { fieldViolations: [{ field: "message.token", description: "Invalid registration token" }] },
        { errorCode: "INVALID_ARGUMENT" },
      ],
    },
  }, 400);
  assertEquals(v.tokenDead, true);
  assertEquals(v.needsAttention, false);
});

Deno.test("INVALID_ARGUMENT + 페이로드 필드 지목 — 토큰을 끄면 안 된다", () => {
  // 이게 이 파일이 존재하는 이유다. 종전 코드는 여기서 토큰을 껐고,
  // 페이로드 버그 한 번이면 그 알림의 수신자 기기가 전부 꺼졌다.
  const v = classifyFcmError({
    error: {
      status: "INVALID_ARGUMENT",
      details: [
        { fieldViolations: [{ field: "message.data[0].value", description: "must be a string" }] },
        { errorCode: "INVALID_ARGUMENT" },
      ],
    },
  }, 400);
  assertEquals(v.tokenDead, false);
  assertEquals(v.needsAttention, true, "우리 버그이므로 사람이 봐야 한다");
});

Deno.test("INVALID_ARGUMENT + 근거 없음 — 애매하면 끄지 않는다", () => {
  // fieldViolations 가 없으면 토큰 탓이라는 근거가 없다. 오탐 비용이 크므로
  // 확신이 없을 때의 기본값은 '살려 둔다' 여야 한다.
  const v = classifyFcmError(
    { error: { status: "INVALID_ARGUMENT", details: [{ errorCode: "INVALID_ARGUMENT" }] } },
    400,
  );
  assertEquals(v.tokenDead, false);
  assertEquals(v.needsAttention, true);
});

Deno.test("THIRD_PARTY_AUTH_ERROR — APNs 설정 문제. 토큰 무관, 사람이 봐야 한다", () => {
  const v = classifyFcmError(
    { error: { status: "UNAUTHENTICATED", details: [{ errorCode: "THIRD_PARTY_AUTH_ERROR" }] } },
    401,
  );
  assertEquals(v.tokenDead, false);
  assertEquals(v.needsAttention, true);
});

Deno.test("일시적 실패는 토큰을 건드리지 않는다", () => {
  for (const [code, status] of [["UNAVAILABLE", 503], ["INTERNAL", 500], ["QUOTA_EXCEEDED", 429]] as const) {
    const v = classifyFcmError({ error: { details: [{ errorCode: code }] } }, status);
    assertEquals(v.tokenDead, false, code);
    assertEquals(v.needsAttention, false, code);
  }
});

Deno.test("코드가 없어도 404 면 대상 없음으로 본다", () => {
  const v = classifyFcmError({}, 404);
  assertEquals(v.tokenDead, true);
  assertEquals(v.code, "404");
});

Deno.test("빈 응답이어도 터지지 않는다", () => {
  const v = classifyFcmError({}, 500);
  assertEquals(v.tokenDead, false);
  assertEquals(v.code, "500");
});

// ── ApnsError.reason (2026-08-22) ────────────────────────────────────────────
// APNs 는 fieldViolations 를 쓰지 않는다. 그래서 종전 규칙으로는 iOS 실패가
// 전부 "우리 페이로드 버그" 로 분류됐고, 죽은 토큰이 영원히 안 지워졌다.

Deno.test("APNs BadDeviceToken — 환경 불일치(dev↔prod). 죽은 토큰이다", () => {
  const v = classifyFcmError(apnsErr("BadDeviceToken"), 400);
  assertEquals(v.tokenDead, true);
  assertEquals(v.needsAttention, false, "토큰 문제이므로 사람을 부르지 않는다");
  assertEquals(v.code, "INVALID_ARGUMENT/BadDeviceToken", "사유가 code 에 남아야 한다");
});

Deno.test("APNs DeviceTokenNotForTopic — 다른 번들의 토큰. 죽은 토큰이다", () => {
  const v = classifyFcmError(apnsErr("DeviceTokenNotForTopic"), 400);
  assertEquals(v.tokenDead, true);
  assertEquals(v.needsAttention, false);
});

Deno.test("APNs ExpiredProviderToken — 우리 인증키 문제. 토큰을 끄면 안 된다", () => {
  // 이 분기가 이 변경에서 가장 위험한 자리다. 허용목록에 잘못 넣으면 키 만료
  // 한 번에 **모든 사용자의 기기가 전부 꺼진다** — #170 이 겪은 사고의 재현이다.
  const v = classifyFcmError(apnsErr("ExpiredProviderToken"), 400);
  assertEquals(v.tokenDead, false, "인증키 문제로 남의 기기를 끄면 안 된다");
  assertEquals(v.needsAttention, true);
});

Deno.test("APNs PayloadTooLarge·BadTopic — 우리 요청 문제. 토큰 무관", () => {
  for (const reason of ["PayloadTooLarge", "BadTopic", "InvalidPushType"]) {
    const v = classifyFcmError(apnsErr(reason), 400);
    assertEquals(v.tokenDead, false, reason);
    assertEquals(v.needsAttention, true, reason);
  }
});

Deno.test("모르는 APNs 사유는 끄지 않는다(허용목록)", () => {
  const v = classifyFcmError(apnsErr("SomeFutureReason"), 400);
  assertEquals(v.tokenDead, false);
  assertEquals(v.needsAttention, true);
});

Deno.test("토큰 필드 지목이 ApnsError 보다 우선한다", () => {
  const err = apnsErr("BadTopic");
  err.error.details.push(
    { fieldViolations: [{ field: "message.token", description: "Invalid" }] } as never,
  );
  assertEquals(classifyFcmError(err, 400).tokenDead, true);
});

// ── summarizeFcmError ───────────────────────────────────────────────────────

Deno.test("요약은 상용구가 아니라 사유를 앞에 놓는다", () => {
  // 종전 `JSON.stringify(details).slice(0,160)` 은 여기서 reason 직전에 잘렸다.
  const s = summarizeFcmError(apnsErr("BadDeviceToken"));
  assertStringIncludes(s, "APNs:BadDeviceToken");
  assertEquals(s.indexOf("APNs:BadDeviceToken"), 0, "맨 앞이어야 잘려도 살아남는다");
});

Deno.test("요약이 짧게 잘려도 사유는 남는다", () => {
  const s = summarizeFcmError(apnsErr("BadDeviceToken"), 24);
  assertStringIncludes(s, "BadDeviceToken");
  assertEquals(s.length <= 24, true);
});

Deno.test("요약에 필드 위반과 메시지도 담긴다", () => {
  const s = summarizeFcmError({
    error: {
      message: "Request contains an invalid argument.",
      details: [{ fieldViolations: [{ field: "message.data[0].value", description: "must be a string" }] }],
    },
  });
  assertStringIncludes(s, "message.data[0].value");
  assertStringIncludes(s, "must be a string");
});

Deno.test("모양을 모르는 응답이어도 요약이 터지지 않는다", () => {
  assertEquals(typeof summarizeFcmError({}), "string");
  assertEquals(typeof summarizeFcmError({ error: {} }), "string");
});
