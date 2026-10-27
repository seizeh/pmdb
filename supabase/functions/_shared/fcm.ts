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
//
// ── 그런데 그 규칙만으로는 iOS 를 못 가른다 (2026-08-22)
//
//   운영에서 INVALID_ARGUMENT 알람이 두 번 울렸다(08-17 접종알림, 08-20 로그인알림).
//   서로 **다른 알림**인데 같은 오류였다. 페이로드는 모든 푸시가 같은 틀을 쓰므로
//   페이로드 버그라면 매번 터져야 한다 — 한 달에 두 번은 그 설명과 맞지 않는다.
//   그리고 오류 본문에 있던 건 `ApnsError` 였다. 안드로이드·웹 토큰은 멀쩡했다.
//
//   원인은 **APNs 는 fieldViolations 를 쓰지 않는다**는 것이다. APNs 는 자기 사유를
//   details[] 안의 `ApnsError.reason` 으로 준다:
//
//     {"@type":"…FcmError",  "errorCode":"INVALID_ARGUMENT"}
//     {"@type":"…ApnsError", "statusCode":400, "reason":"BadDeviceToken"}
//
//   그래서 violatesTokenField() 는 항상 false 였고, 결과가 두 방향으로 틀렸다:
//     · tokenDead=false      → **죽은 토큰을 영원히 안 지운다.** 다음 푸시가 또
//                              그 토큰을 때리고 또 알람이 온다(자기강화).
//     · needsAttention=true  → "우리 페이로드 버그" 라고 **틀린 곳을 지목한다.**
//
//   증거: 계정 하나에 활성 iOS 토큰이 17개 쌓여 있었다(전체 43). 실기기는 한두 대다.
//   다른 계정은 UNREGISTERED 경로로 정상 정리돼 1개씩만 남아 있었다.
//
//   #170 이 고친 것의 **반대편 오류**다. 그때는 INVALID_ARGUMENT 를 무조건 토큰
//   사망으로 봐서 멀쩡한 기기를 껐고, 지금은 APNs 계열을 전부 페이로드 버그로 봐서
//   죽은 토큰을 못 지웠다. 어느 쪽이든 원인은 하나 — **근거 없이 단정한 것**이다.
//   그래서 아래도 허용목록(allowlist)으로 간다: APNs 가 토큰을 명시적으로 지목한
//   사유만 죽었다고 보고, 모르는 사유는 살려 두고 사람에게 넘긴다.

export interface FcmErrorBody {
  error?: {
    status?: string;
    message?: string;
    details?: Array<{
      "@type"?: string;
      errorCode?: string;
      /// APNs 전용 — FCM 은 fieldViolations 를 쓰는데 APNs 는 이 필드를 쓴다.
      reason?: string;
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

/// APNs 가 **기기 토큰을 명시적으로 지목한** 사유들. 이것만 죽었다고 본다.
///   BadDeviceToken         — 토큰이 잘못됐거나 **환경이 다르다**(개발↔프로덕션).
///                            TestFlight 빌드와 Xcode 실행 빌드가 섞이면 나온다.
///   DeviceTokenNotForTopic — 다른 번들 ID 로 발급된 토큰.
///   Unregistered           — 앱 삭제. 보통 FCM 이 UNREGISTERED 로 접어서 위쪽에서
///                            먼저 걸리지만, 접히지 않고 올 때를 위해 둔다.
///
/// ⚠️ 여기에 없는 사유는 **넣지 않는다.** 특히 헷갈리는 둘:
///   ExpiredProviderToken / InvalidProviderToken — 우리 APNs 인증키 문제다. 토큰을
///     끄면 **모든 사용자의 기기가 우리 키 만료 한 번에 전부 꺼진다.**
///   BadTopic · PayloadTooLarge · BadPriority · InvalidPushType — 우리 요청 문제다.
const APNS_TOKEN_DEAD_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

/// details[] 에서 ApnsError 의 reason 을 꺼낸다. 없으면 null.
function apnsReason(err: FcmErrorBody): string | null {
  for (const d of err.error?.details ?? []) {
    // `@type` 은 `type.googleapis.com/google.firebase.fcm.v1.ApnsError` 형태다.
    // 전체 문자열을 비교하면 FCM 이 경로를 바꿀 때 조용히 안 걸리므로 끝만 본다.
    if ((d["@type"] ?? "").endsWith("ApnsError")) {
      const r = (d.reason ?? "").trim();
      if (r) return r;
    }
  }
  return null;
}

/// 사람이 읽을 요약 — **잘려도 정보가 남는 순서**로 만든다.
///
/// 종전에는 `JSON.stringify(details).slice(0, 160)` 이었다. details[0] 은 언제나
/// `{"@type":"…FcmError","errorCode":"…"}` 라는 상용구라, 160자가 그 상용구와
/// `{"@type":"…ApnsError",` 까지만 채우고 **정작 reason 직전에서 잘렸다.** 알람을
/// 받아도 원인을 알 수 없었던 이유다. 그래서 신호를 앞에 놓고 상용구는 버린다.
export function summarizeFcmError(err: FcmErrorBody, max = 600): string {
  const parts: string[] = [];
  const reason = apnsReason(err);
  if (reason) parts.push(`APNs:${reason}`);
  for (const d of err.error?.details ?? []) {
    for (const v of d.fieldViolations ?? []) {
      parts.push(`${v.field ?? "?"} — ${v.description ?? ""}`.trim());
    }
  }
  if (err.error?.message) parts.push(err.error.message);
  const s = parts.length > 0 ? parts.join(" | ") : JSON.stringify(err.error ?? err);
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

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
    // ① FCM 이 토큰 필드를 지목했으면 죽은 토큰이 확실하다.
    if (violatesTokenField(err)) return { code, tokenDead: true, needsAttention: false };

    // ② APNs 가 사유를 말했으면 그 사유로 가른다(위 주석 참고 — APNs 는
    //    fieldViolations 를 쓰지 않으므로 ①로는 영원히 안 걸린다).
    //    사유를 code 에 붙여 둔다 — push_error·알람에 그대로 실려 "무엇이었나" 가
    //    한 번에 보인다(push_error 는 자유 텍스트라 파싱하는 곳이 없다).
    const reason = apnsReason(err);
    if (reason !== null) {
      const tokenDead = APNS_TOKEN_DEAD_REASONS.has(reason);
      return { code: `${code}/${reason}`, tokenDead, needsAttention: !tokenDead };
    }

    // ③ 근거가 없으면 끄지 않는다(오탐 비용이 크다). 사람에게 넘긴다.
    return { code, tokenDead: false, needsAttention: true };
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
