-- 웹 푸시(Phase D) — device_tokens.platform 에 'web' 허용
--
-- 종전 제약은 ('ios','android') 뿐이라 웹 FCM 토큰은 **INSERT 자체가 거부**된다.
-- register_device_token 은 platform 을 검증하지 않고 그대로 넣으므로, 이 제약을
-- 풀지 않으면 클라이언트가 아무리 맞아도 등록이 조용히 실패한다
-- (notification_type CHECK 를 빠뜨려 트리거가 조용히 삼키던 것과 같은 부류).
--
-- 발송 경로는 손댈 필요가 없다 — send-push 는 FCM v1 단일 엔드포인트라
-- 플랫폼과 무관하게 같은 토큰 필드로 나간다.

alter table public.device_tokens
  drop constraint if exists device_tokens_platform_check;

alter table public.device_tokens
  add constraint device_tokens_platform_check
  check (platform in ('ios', 'android', 'web'));
