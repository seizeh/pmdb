-- 업체 서류 파기 크론 연결 (0025 §3.3 · 운영점검주기 v1.2 의 "크론 연결 대기" 해소).
-- 서류 파일은 스토리지 API 가 필요해 SQL 크론이 직접 못 지운다 → pg_cron 이 pg_net 으로
-- purge-business-docs 엣지를 매일 호출(send-push 의 push_config 패턴 그대로).
-- 시크릿은 DB 가 생성하고, 엣지 env BUSINESS_PURGE_SECRET 를 이 값과 일치시킨다.

create table if not exists app.business_purge_config (
  id             boolean primary key default true,
  function_url   text not null,
  trigger_secret text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  constraint business_purge_config_singleton check (id)
);
alter table app.business_purge_config enable row level security; -- 정책 없음 = definer/크론 전용

insert into app.business_purge_config(id, function_url)
values (true, 'https://vyatppuxmpulqtxevfpk.supabase.co/functions/v1/purge-business-docs')
on conflict (id) do nothing;

-- 매일 04:13 실행 (retention-purge 03:23 이 행·큐를 정리한 뒤 파일 처리 — 순서 여유 50분).
do $$ begin
  if exists (select 1 from cron.job where jobname = 'business-docs-purge') then
    perform cron.unschedule('business-docs-purge');
  end if;
end $$;
select cron.schedule('business-docs-purge', '13 4 * * *',
  $$select net.http_post(
      url := (select function_url from app.business_purge_config),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-purge-secret', (select trigger_secret from app.business_purge_config)),
      body := '{}'::jsonb
  );$$);
