-- 신고 접수 즉시 관리자 알림 — 약관 §12③ "24시간 내 조치" 의 이행 장치.
-- 지금까지 신고 관측은 주간 점검 스윕뿐이라 최악의 경우 접수 후 7일 뒤에야 봤다.
-- app.ops_alarm_fire 재사용: ops_alarms 기록 + 활성 관리자 전원 notifications
-- (→ trg_notifications_push → send-push → FCM). 쿨다운 30분 — 폭주는 병합하되
-- 각 30분 창의 첫 신고는 즉시 발송된다.

create function app.tg_reports_alert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform app.ops_alarm_fire(
    'report:new',
    30,
    '신고 접수',
    format('%s 신고가 접수됐습니다 — 관리자 콘솔에서 확인하세요.', new.target_type),
    jsonb_build_object(
      'report_id', new.id,
      'target_type', new.target_type,
      'categories', new.categories
    )
  );
  return new;
exception when others then
  -- 알림 실패가 신고 접수 자체를 막으면 안 된다.
  raise warning 'tg_reports_alert failed: %', sqlerrm;
  return new;
end $$;

create trigger trg_reports_alert
  after insert on public.reports
  for each row execute function app.tg_reports_alert();
