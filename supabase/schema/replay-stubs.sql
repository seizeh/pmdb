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
-- retention-purge / business-docs-purge 스케줄 등록(20260711130000, 20260715100000).
-- pg_cron 은 shared_preload_libraries 설정이 필요해 서비스 컨테이너에 올릴 수 없다.
-- 스케줄 등록이 성공하기만 하면 되므로 잡 목록만 흉내 낸다.
create schema if not exists cron;

create table if not exists cron.job (
  jobid    bigserial primary key,
  jobname  text unique,
  schedule text,
  command  text
);

create or replace function cron.schedule(job_name text, schedule text, command text)
returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid
$$;

create or replace function cron.unschedule(job_name text)
returns boolean language sql as $$
  delete from cron.job where jobname = job_name returning true
$$;

-- ── realtime ───────────────────────────────────────────────────────────────
-- alter publication supabase_realtime add table …(20260608071651 등)
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;
