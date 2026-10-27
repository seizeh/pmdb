-- sync-dong-centroids 를 시스템 배치로 전환 — pg_cron 매시 스윕 (push-sweep 패턴)
--
-- 종전에는 앱이 지도 클러스터를 그릴 때 로그인 JWT 로 직접 호출하는 lazy backfill
-- 이었다. 사용자 신원이 판정에 아무 역할이 없는 유지보수 작업이라(uid 는 리밋 키로만
-- 사용) 시크릿 게이트 + 크론으로 옮긴다. 시드가 없으면 엣지가 외부 호출 0회로 즉시
-- 끝나므로 매시 무조건 호출해도 비용이 없다. 채움이 최대 1시간 늦어지는 대가는
-- posts_by_region 의 사용자 평균 폴백이 흡수한다.
--
-- 설정 테이블은 push_config·business_purge_config 와 같은 형태의 싱글턴.
-- 시크릿 값은 마이그레이션에 싣지 않는다 — 적용 후 운영에서 직접 INSERT (전례 동일).

create table app.dong_sync_config (
  function_url   text not null,
  trigger_secret text not null
);

comment on table app.dong_sync_config is
  'sync-dong-centroids 크론 호출 설정 싱글턴 — push_config 패턴. 값은 out-of-band 주입';

-- app 스키마 RLS 벨트(t28) — 정책 없는 RLS = service_role/definer 전용
alter table app.dong_sync_config enable row level security;

select cron.schedule(
  'dong-centroid-sweep',
  '7 * * * *',
  $$ select net.http_post(
       url := (select function_url from app.dong_sync_config),
       headers := jsonb_build_object(
         'Content-Type', 'application/json',
         'x-sync-secret', (select trigger_secret from app.dong_sync_config)),
       body := '{}'::jsonb)
     where exists (select 1 from app.dong_sync_config) $$
);
