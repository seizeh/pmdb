-- 테스트 DB 준비 — schema.sql(스냅샷) 적용 전에 실행한다.
-- 스냅샷은 public·app 스키마만 담으므로(-n 제한 덤프에는 CREATE EXTENSION 미포함),
-- 함수/컬럼이 의존하는 확장과 Supabase 기본 롤을 먼저 만들어 준다.

create extension if not exists postgis;   -- dong_centroids 등 geometry 컬럼
create extension if not exists pg_net;    -- app.on_notification_push 의 net.http_post
create extension if not exists pgtap;     -- 테스트 프레임워크

-- supabase/postgres 이미지에는 이미 있지만, 없으면 만들어 준다(멱등).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;
