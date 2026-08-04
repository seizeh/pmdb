// classifyFcmError — 오탐(살아 있는 토큰을 끄는 것)이 나지 않는가.
//
// 실행: deno test supabase/functions/_shared/fcm_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { classifyFcmError } from "./fcm.ts";

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
