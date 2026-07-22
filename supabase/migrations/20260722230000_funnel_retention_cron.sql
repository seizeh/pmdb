-- ============================================================================
-- 퍼널 원시 이벤트 보존 1년 크론 (0028 §7 — "원시 이벤트 1년, 경과분 배치 삭제").
-- 장기 추세가 필요해지면 삭제 전 집계 뷰/스냅샷을 먼저 도입할 것.
-- 시각: 03:53 — retention-purge(03:23)·withdrawn-users-purge(03:43) 뒤,
-- business-docs-purge(04:13) 앞.
-- ============================================================================

do $$ begin
  if exists (select 1 from cron.job where jobname = 'funnel-events-retention') then
    perform cron.unschedule('funnel-events-retention');
  end if;
end $$;
select cron.schedule('funnel-events-retention', '53 3 * * *',
  $$delete from app.funnel_events where created_at < now() - interval '1 year'$$);
