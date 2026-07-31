-- 클라이언트 오류 수집 — 외부 리포팅 서비스 대신 우리 DB 로 (0031)
--
-- 배경: 앱이 깨져도 아무도 몰랐다(pmdart #157). 외부 서비스(Sentry)를 붙였다가
-- 우리 DB 로 받는 쪽으로 바꿨다 — Supabase 는 **이미 처리위탁 수탁자**라
-- 개인정보처리방침을 고칠 필요가 없고, 관리자 대시보드에 그대로 붙는다.
-- 잃는 것은 그룹핑·중복제거·릴리스 비교다(베타 규모에서는 값이 작다고 판단).
--
-- ⚠️ 이 RPC 는 anon 에게도 열린다 — 웹은 비로그인 방문자가 주 진입로라 그들의
-- 오류를 못 받으면 목적의 절반이 사라진다. 대신 **공개 쓰기 엔드포인트**가 되므로:
--   · 레이트리밋(rate_limit_hit) 을 반드시 통과해야 INSERT
--   · 모든 입력을 서버에서 잘라 저장(길이 폭탄 차단)
--   · 실패해도 예외를 던지지 않는다(오류 보고가 또 오류를 만들면 안 된다)
--   · 등급 'reported' 만 받는다 — ignored/userFacing 은 클라이언트 링 버퍼에만 남는다

create table if not exists app.client_errors (
  id          bigint generated always as identity primary key,
  user_id     uuid references public.users(id) on delete set null,
  where_key   varchar(80)  not null,          -- ErrorReporter 의 where (기능 경로)
  message     varchar(500) not null,
  stack       text,
  platform    varchar(10),                    -- web | ios | android | …
  app_release varchar(40),                    -- pawmate@2.0.0+10
  extra       jsonb,
  created_at  timestamptz  not null default now(),
  constraint client_errors_stack_len check (stack is null or length(stack) <= 8000)
);

create index if not exists client_errors_recent_idx
  on app.client_errors (created_at desc);
-- 같은 지점이 얼마나 자주 터지는지 — 그룹핑이 없는 대신 이걸로 센다.
create index if not exists client_errors_where_idx
  on app.client_errors (where_key, created_at desc);

alter table app.client_errors enable row level security; -- 정책 0, definer/service_role 전용

comment on table app.client_errors is
  '클라이언트 오류 리포팅(reported 등급만). 30일 보존 후 app.cleanup_retention 이 파기 (0031)';

-- ── 수집 RPC ───────────────────────────────────────────────────────────────
create or replace function public.record_client_error(
  p_where   text,
  p_message text,
  p_stack   text default null,
  p_platform text default null,
  p_release  text default null,
  p_extra    jsonb default null
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_ok  boolean;
begin
  if coalesce(p_where, '') = '' or coalesce(p_message, '') = '' then
    return; -- 조용히 무시(오류 보고가 예외를 던지면 안 된다)
  end if;

  -- 로그인 사용자는 계정별로, 비로그인은 **전체 합산**으로 막는다.
  -- 익명은 식별자가 없어 개별 제한이 불가능하다 — 전역 상한으로 홍수만 막는다.
  v_ok := public.rate_limit_hit(
            case when v_uid is null then 'cerr:anon' else 'cerr:' || v_uid::text end,
            case when v_uid is null then 300 else 30 end,
            60);
  if not v_ok then
    return;
  end if;

  insert into app.client_errors
    (user_id, where_key, message, stack, platform, app_release, extra)
  values
    (v_uid,
     left(p_where, 80),
     left(p_message, 500),
     left(p_stack, 8000),
     left(p_platform, 10),
     left(p_release, 40),
     case when p_extra is null then null
          when length(p_extra::text) > 4000 then null  -- 과대 페이로드는 버린다
          else p_extra end);
exception when others then
  return; -- 어떤 이유로든 실패해도 앱에 예외를 돌려주지 않는다
end $function$;

revoke all on function public.record_client_error(text,text,text,text,text,jsonb) from public;
grant execute on function public.record_client_error(text,text,text,text,text,jsonb)
  to anon, authenticated, service_role;

-- ── 관리자 조회 ────────────────────────────────────────────────────────────
-- 컬럼 권한 때문에 직접 SELECT 를 열지 않고 is_admin 게이트 definer RPC 로 준다
-- (admin_* RPC 들과 같은 관용구).
create or replace function public.admin_client_errors(
  p_where  text default null,
  p_limit  integer default 100,
  p_offset integer default 0
) returns table (
  id bigint, user_id uuid, nickname text, where_key text, message text,
  stack text, platform text, app_release text, extra jsonb, created_at timestamptz
)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select e.id, e.user_id, coalesce(u.nickname, '(비로그인)')::text,
           e.where_key::text, e.message::text, e.stack,
           e.platform::text, e.app_release::text, e.extra, e.created_at
      from app.client_errors e
      left join public.users u on u.id = e.user_id
     where p_where is null or e.where_key = p_where
     order by e.created_at desc
     limit greatest(least(coalesce(p_limit, 100), 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end $function$;

revoke all on function public.admin_client_errors(text,integer,integer) from public, anon;
grant execute on function public.admin_client_errors(text,integer,integer)
  to authenticated, service_role;

-- 발생 지점별 집계 — 그룹핑이 없는 대신 '어디가 자주 터지나' 를 이걸로 본다.
create or replace function public.admin_client_error_summary(p_hours integer default 24)
returns table (where_key text, hits bigint, users bigint, last_at timestamptz)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select e.where_key::text, count(*)::bigint,
           count(distinct e.user_id)::bigint, max(e.created_at)
      from app.client_errors e
     where e.created_at > now() - make_interval(hours => greatest(coalesce(p_hours, 24), 1))
     group by e.where_key
     order by count(*) desc;
end $function$;

revoke all on function public.admin_client_error_summary(integer) from public, anon;
grant execute on function public.admin_client_error_summary(integer)
  to authenticated, service_role;
create or replace function app.cleanup_retention() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  delete from public.phone_verifications where created_at < now() - interval '1 day';

  delete from public.location_verifications where created_at < now() - interval '6 months';

  delete from public.photo_verifications pv
   where pv.created_at < now() - interval '6 months'
     and not exists (select 1 from public.pets  p  where p.ai_ref_verification_id = pv.id)
     and not exists (select 1 from public.posts po where po.photo_verification_id = pv.id);

  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where created_at < now() - interval '6 months'
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);

  update public.posts p
     set actual_lat = null, actual_lng = null
   where (p.visibility_status like 'deleted_%'
          or exists (select 1 from public.users u where u.id = p.user_id and u.status = 'deleted'))
     and (p.actual_lat is not null or p.actual_lng is not null);

  delete from public.post_views where viewed_at < now() - interval '3 months';

  delete from app.auth_logs where created_at < now() - interval '3 months';

  delete from app.location_usage_logs where used_at < now() - interval '6 months';

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '30 days'
     and exists (select 1 from public.users u
                  where u.id = bp.user_id and u.status = 'deleted');

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '6 months';

  delete from app.client_errors where created_at < now() - interval '30 days';

  delete from public.chat_messages
   where is_deleted = true
     and coalesce(deleted_at, updated_at, created_at) < now() - interval '30 days';
$$;
comment on function public.record_client_error(text,text,text,text,text,jsonb) is
  '클라이언트 오류 수집(0031). anon 포함 공개 — 레이트리밋·길이 제한·예외 삼킴이 전제.';
