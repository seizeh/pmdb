-- refresh-token 1단계 하드닝 (리뷰 반영):
--   #1 change_password_svc 에 세션 게이트(status + token_version) 내장 — 엣지 change-password
--      가 tv 불일치(전역 무효화된) 토큰을 통과시키던 갭 차단. app.uid 게이트와 동일 기준.
--   #5 비번 정책 로직 단일화: app._set_password 코어 → change_password / change_password_svc 가 래핑.
--   #2 login/refresh 기본 레이트리밋용 rate_limit_hit + app.rate_limits.

-- #5) 비번 변경 코어(세션 검증 없음). 정책(length<6, bf 12, 현재비번 확인)을 한 곳에.
create or replace function app._set_password(p_user uuid, p_current text, p_new text)
returns void language plpgsql security definer set search_path to '' as $function$
begin
  if p_new is null or length(p_new) < 6 then
    raise exception 'weak_password' using errcode='P0001';
  end if;
  if not exists (
    select 1 from public.users
    where id = p_user and password_hash = extensions.crypt(p_current, password_hash)
  ) then
    raise exception 'invalid_current' using errcode='P0001';
  end if;
  update public.users
     set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 12))
   where id = p_user;
end $function$;
revoke all on function app._set_password(uuid,text,text) from public, anon, authenticated;

-- 앱 직접 호출 RPC(레거시 경로): app.uid() 게이트(이미 tv+status 검증) 후 코어 호출.
create or replace function public.change_password(p_current text, p_new text)
returns void language plpgsql security definer set search_path to '' as $function$
declare v_id uuid := app.uid();
begin
  if v_id is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  perform app._set_password(v_id, p_current, p_new);
end $function$;

-- #1) 엣지용: uid + tv 를 명시로 받아 세션 유효성(status active + token_version 일치)을
--     먼저 검증(app.uid 와 동일 기준) 후 코어 호출. 3인자 구버전은 제거.
drop function if exists public.change_password_svc(uuid, text, text);
create or replace function public.change_password_svc(p_user uuid, p_current text, p_new text, p_tv integer)
returns void language plpgsql security definer set search_path to '' as $function$
begin
  if p_user is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  if not exists (
    select 1 from public.users
    where id = p_user and status = 'active' and token_version = coalesce(p_tv, 0)
  ) then
    raise exception 'not_authenticated' using errcode='42501';
  end if;
  perform app._set_password(p_user, p_current, p_new);
end $function$;

-- #2) 고정 윈도우 레이트리밋. bucket = key:windowId, 윈도우당 count. count<=max 이면 허용.
create table if not exists app.rate_limits (
  bucket     text primary key,
  count      integer not null default 0,
  expires_at timestamptz not null
);
create index if not exists rate_limits_expires_idx on app.rate_limits(expires_at);
alter table app.rate_limits enable row level security; -- 정책0, service_role/definer 전용

create or replace function public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer)
returns boolean language plpgsql security definer set search_path to '' as $function$
declare
  v_win bigint := floor(extract(epoch from now()) / greatest(p_window_seconds, 1));
  v_bucket text := p_key || ':' || v_win;
  v_count integer;
begin
  insert into app.rate_limits(bucket, count, expires_at)
  values (v_bucket, 1, now() + make_interval(secs => p_window_seconds))
  on conflict (bucket) do update set count = app.rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_max;  -- true=허용, false=제한
end $function$;

-- 권한: 엣지 전용(service_role). PUBLIC 기본 EXECUTE 회수. (change_password 는 기존 grants 유지)
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.change_password_svc(uuid,text,text,integer)',
    'public.rate_limit_hit(text,integer,integer)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end $$;
