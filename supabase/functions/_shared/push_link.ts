// 웹 푸시 알림을 눌렀을 때 열 주소 — send-push 가 웹 토큰에만
// `webpush.fcm_options.link` 로 싣는다.
//
// 왜 필요한가: 웹(app.pawmate.kr)의 서비스워커(pmdart web/firebase-messaging-sw.js)는
// 알림을 누르면 이 링크로 보낸다. 링크가 없으면 갈 곳을 몰라 열린 탭을 앞으로
// 가져오거나 첫 화면만 연다. 2026-10-26 까지는 이 블록이 아예 없어서 웹 알림
// 클릭이 전부 그렇게 동작했다(web-port 설계는 이 블록을 전제했는데 빠져 있었다).
//
// 웹이 직접 열 수 있는 화면은 진입 경로 셋뿐이다(pmdart lib/utils/web_link.dart):
//   /p/<postId>  게시글 상세    ← resource_type 'post'
//   /u/<userId>  사용자 프로필  ← resource_type 'user'
//   /r/<facilityId> 는 "그 매장의 후기 작성" 진입이라 알림 목적지로 쓰지 않는다.
// 채팅(웹은 채팅이 앱 전용)·보안·공지·초대처럼 웹 화면이 없는 알림은 null 이다.
//
// FCM 은 fcm_options.link 에 HTTPS 절대 주소를 요구한다. 기준 주소가 비었거나
// https 가 아니면 링크를 만들지 않는다 — 잘못된 링크로 발송이 400 으로 거절되면
// 웹 알림이 통째로 사라지기 때문이다(링크가 없는 편이 낫다).

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 알림의 resource 로 웹 링크를 만든다. 웹 화면이 없거나 만들 수 없으면 null. */
export function webPushLink(
  base: string | null | undefined,
  resourceType: string | null | undefined,
  resourceId: string | null | undefined,
): string | null {
  const b = (base ?? "").trim().replace(/\/+$/, "");
  if (!/^https:\/\/[^/\s]+(\/\S+)?$/.test(b)) return null;
  if (!resourceId || !UUID.test(resourceId)) return null;
  switch (resourceType) {
    case "post":
      return `${b}/p/${resourceId}`;
    case "user":
      return `${b}/u/${resourceId}`;
    default:
      return null;
  }
}
