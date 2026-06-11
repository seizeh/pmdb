-- 공동보호자 대리 수락 알림 타입(application_accepted_by_co)을 notifications CHECK 허용목록에 추가.
-- (알림 insert 트리거는 예외를 무시하므로, 누락 시 알림이 조용히 안 생긴다)

alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (notification_type::text = any (array[
    'chat_message','post_application','post_comment','pawing_new_post',
    'application_accepted','application_accepted_by_co','review_received',
    'system_notice','location_expired','chat_read_receipt','unread_sync'
  ]::text[]));
