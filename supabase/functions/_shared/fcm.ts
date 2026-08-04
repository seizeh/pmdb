// FCM v1 오류 분류 — **어떤 실패가 "이 토큰은 죽었다" 인가.**
//
// 이 판정이 틀리면 비용이 한쪽으로만 크다:
//
//   오탐(살아 있는 토큰을 죽었다고 판정) → 그 기기를 **비활성화**한다. 사용자는
//     그때부터 푸시를 못 받고, 본인은 그 사실을 모른다. 앱을 다시 열어 토큰을
//     재등록하기 전까지 조용히 침묵한다.
//   미탐(죽은 토큰을 살아 있다고 판정) → FCM 호출 몇 번이 낭비된다. 다음번
//     UNREGISTERED 에서 정리된다.
//
// 그래서 **토큰 문제라고 확신할 때만** 죽었다고 한다.
//
// ── 종전 코드의 문제
//   `code === "INVALID_ARGUMENT"` 이면 무조건 죽은 토큰으로 처리했다. 그런데
//   INVALID_ARGUMENT 는 **요청이 잘못됐다** 는 뜻이고, 토큰이 아니라 페이로드가
//   잘못돼도 나온다(제목/본문 타입 오류, data 값이 문자열이 아님, 크기 초과 …).
//   페이로드 버그면 그 알림의 **모든 토큰**이 같은 오류를 받으므로, 한 번의
//   배포 실수로 수신자의 기기가 전부 꺼진다. 우리 잘못을 사용자 기기로 갚는 셈이다.
//
// ── 무엇으로 가르는가
//   FCM v1 은 잘못된 필드를 details[].fieldViolations[].field 로 알려 준다.
//   토큰 문제면 그 field 가 `message.token` 이다. 그게 아니면 우리 페이로드 문제다.

export interface FcmErrorBody {
  error?: {
    status?: string;
    details?: Array<{
      errorCode?: string;
      fieldViolations?: Array<{ field?: string; description?: string }>;
    }>;
  };
}

export interface FcmVerdict {
  /// 로그·집계에 쓸 오류 코드.
  code: string;
  /// 이 토큰을 비활성화해도 되는가.
  tokenDead: boolean;
  /// 우리 쪽 잘못이라 사람이 봐야 하는가(재시도해도 낫지 않는다).
  needsAttention: boolean;
}

/// 토큰이 원인임이 **확실한** 코드들.
///   UNREGISTERED       — 앱 삭제·토큰 만료. 전형적인 죽은 토큰.
///   NOT_FOUND          — 위와 같은 뜻의 옛 표기.
///   SENDER_ID_MISMATCH — 다른 Firebase 프로젝트의 토큰. 우리는 영원히 못 보낸다.
const TOKEN_DEAD_CODES = new Set([
  "UNREGISTERED",
  "NOT_FOUND",
  "SENDER_ID_MISMATCH",
]);

function violatesTokenField(err: FcmErrorBody): boolean {
  for (const d of err.error?.details ?? []) {
    for (const v of d.fieldViolations ?? []) {
      // `message.token` 이 정식이지만 표기가 흔들려도 잡히도록 마지막 조각을 본다.
      const f = (v.field ?? "").toLowerCase();
      if (f === "token" || f.endsWith(".token")) return true;
    }
  }
  return false;
}

export function classifyFcmError(err: FcmErrorBody, httpStatus: number): FcmVerdict {
  const code = err.error?.details?.find((d) => d.errorCode)?.errorCode ??
    err.error?.status ??
    String(httpStatus);

  if (TOKEN_DEAD_CODES.has(code)) {
    return { code, tokenDead: true, needsAttention: false };
  }

  if (code === "INVALID_ARGUMENT") {
    // 토큰 필드를 지목했으면 죽은 토큰, 아니면 **우리 페이로드 버그**다.
    const tokenDead = violatesTokenField(err);
    return { code, tokenDead, needsAttention: !tokenDead };
  }

  // APNs 키·인증서 문제. 토큰과 무관하고 재시도로 낫지 않으며, iOS 전체가 조용히
  // 죽는다 — 저볼륨에서는 "실패 건수" 임계에도 안 걸리므로 따로 알려야 한다.
  if (code === "THIRD_PARTY_AUTH_ERROR") {
    return { code, tokenDead: false, needsAttention: true };
  }

  // UNAVAILABLE·INTERNAL·QUOTA_EXCEEDED 등 일시적 실패. 토큰은 건드리지 않는다.
  // 404 는 위 코드로 안 잡혔더라도 대상 없음이므로 죽은 토큰으로 본다.
  return { code, tokenDead: httpStatus === 404, needsAttention: false };
}
