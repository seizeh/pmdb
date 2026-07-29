-- 마이그레이션 리플레이 전용 스텁 — prelude.sql 다음, baseline.sql 앞에 적용한다.
--
-- 마이그레이션 몇 개가 public·app 밖의 Supabase 플랫폼 객체를 건드린다.
-- 운영 DB 에는 당연히 있지만 맨바닥 postgres 컨테이너에는 없거나(pg_cron 처럼)
-- 컨테이너 설정을 바꿔야만 올라간다. 스냅샷 비교 대상은 public·app 뿐이므로
-- (dump_schema.sh 의 -n 인자) 여기서 만드는 것들은 diff 에 섞이지 않는다.
--
-- 목적은 "마이그레이션이 끝까지 흘러가게" 하는 것이지 플랫폼을 재현하는 게 아니다.
-- 따라서 동작은 흉내만 내고 검증하지 않는다.

-- ── storage ────────────────────────────────────────────────────────────────
-- 버킷 생성 + business-docs 접근 정책(20260608150932, 20260714120000)
create schema if not exists storage;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz default now()
);

create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets(id),
  name       text,
  owner      uuid,
  created_at timestamptz default now()
);

alter table storage.objects enable row level security;

-- 운영에서는 storage 확장이 제공한다. 경로 세그먼트 배열을 돌려주면 충분하다.
create or replace function storage.foldername(name text)
returns text[] language sql immutable as $$
  select string_to_array(name, '/')
$$;

-- ── pg_cron ────────────────────────────────────────────────────────────────
-- 스텁이 없다. 20260701150000 이 `create extension if not exists pg_cron` 으로
-- 진짜 확장을 올리고, cron 스케줄을 쓰는 마이그레이션은 전부 그 뒤에 온다.
-- (그러려면 서버의 cron.database_name 이 이 DB 여야 한다 — CI 가 설정해 준다.
--  로컬은 README 의 docker 실행 예시 참고.)

-- ── 기본 권한(ALTER DEFAULT PRIVILEGES) ────────────────────────────────────
-- Supabase 프로젝트는 public 스키마에 기본 권한이 걸려 있어, 새로 만든 테이블이
-- 아무 GRANT 없이도 anon/authenticated/service_role 권한을 갖는다. 맨바닥 DB 에는
-- 없으므로 마이그레이션이 만든 객체의 ACL 이 운영과 달라진다.
--
-- 아래 값은 운영 DB 에서 그대로 읽어온 것이다(pg_default_acl, defaclrole=postgres):
--   테이블   arwdDxtm(ALL)          → postgres, anon, authenticated, service_role
--   시퀀스   rwU(SELECT,UPDATE,USAGE)→ postgres, anon, authenticated, service_role
--   함수     X(EXECUTE)             → postgres, authenticated, service_role  (PUBLIC 없음)
-- app 스키마에는 기본 권한이 걸려 있지 않다(운영도 동일).
alter default privileges in schema public
  grant all on tables to postgres, anon, authenticated, service_role;

alter default privileges in schema public
  grant select, update, usage on sequences to postgres, anon, authenticated, service_role;

-- 함수 기본값에서 PUBLIC 을 먼저 걷어내야 운영과 같아진다
-- (그대로 두면 PUBLIC=EXECUTE 가 남아 REVOKE … FROM PUBLIC 유무로 diff 가 난다).
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public
  grant execute on functions to postgres, authenticated, service_role;

-- ── realtime ───────────────────────────────────────────────────────────────
-- alter publication supabase_realtime add table …(20260608071651 등)
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;
