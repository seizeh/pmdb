-- 공유 함수 정의 불변식 — 병렬 create or replace 재정의로 조건이 조용히 유실되는
-- 사고의 회귀 가드(2026-07 실제 사고 2건: pawing 얼굴 필터, retention 파기 항목).
begin;
set local search_path = public, app, extensions;
select plan(6);

select ok(
  pg_get_functiondef('app.dispatch_engagement_notifications'::regproc)
    ilike '%w.context = p.authored_as%',
  'pawing_new_post 는 같은 얼굴 팔로워에게만 (얼굴 필터)'
);
select ok(
  pg_get_functiondef('app.dispatch_engagement_notifications'::regproc)
    ilike '%pet_in_post%',
  'pawing_new_post 는 pet_in_post 와 중복 발송 억제'
);

select ok(
  pg_get_functiondef('app.cleanup_retention'::regproc) ilike '%app.auth_logs%',
  'retention: 접속 로그(auth_logs) 3개월 파기 포함'
);
select ok(
  pg_get_functiondef('app.cleanup_retention'::regproc) ilike '%location_usage_logs%',
  'retention: 위치 이용 기록 6개월 파기 포함'
);
select ok(
  pg_get_functiondef('app.cleanup_retention'::regproc)
    ilike '%chat_messages%is_deleted = true%',
  'retention: 삭제된 채팅 30일 유예 파기 포함'
);

select ok(
  pg_get_functiondef('app.tg_notify_review'::regproc) ilike '%새 후기를 받았어요%',
  '후기 알림 문구(후기 용어 통일) 유지'
);

select * from finish();
rollback;
