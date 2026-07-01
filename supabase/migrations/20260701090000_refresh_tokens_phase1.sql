-- Refresh-Token + Session-Version 백엔드 1단계 (설계: docs/refresh-token-flow-design.md)
-- 전부 추가/하위호환: 기존 30일 access(tv 클레임 없음)는 token_version 기본 0과 일치해 무중단.
-- 모든 RPC 는 public 스키마(.rpc 노출) + SECURITY DEFINER + EXECUTE 는 service_role 만
-- (엣지 함수가 service_role 로 호출). 앱/anon 은 직접 호출 불가.

-- 1) 세션 epoch. bump 시 그 사용자의 모든 access 즉시 무효(app.uid 가 매 요청 비교).
alter table public.users add column if not exists token_version integer not null default 0;

-- 2) refresh 토큰 저장(app 스키마 — PostgREST 비노출). 원문 미저장, sha256 해시만.
create table if not exists app.refresh_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  token_hash  text not null unique,
  family_id   uuid not null,
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  absolute_expires_at timestamptz not null,
  revoked_at  timestamptz,
  replaced_by uuid references app.refresh_tokens(id) on delete set null,
  user_agent  text
);
create index if not exists refresh_tokens_user_idx   on app.refresh_tokens(user_id);
create index if not exists refresh_tokens_family_idx on app.refresh_tokens(family_id);
alter table app.refresh_tokens enable row level security;
-- 정책 0개 + GRANT 없음 → service_role(및 정의자 RPC)만 접근.

-- 3) app.uid() 에 token_version 게이트 추가(status 게이트와 동일 행 읽기라 비용≈0).
--    JWT tv 클레임 ≠ users.token_version → NULL(로그아웃). 클레임 없음=0(레거시 하위호환).
create or replace function app.uid()
returns uuid language sql stable security definer set search_path to ''
as $function$
  select u.id
  from public.users u
  where u.id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'sub','')::uuid
    and u.status = 'active'
    and u.token_version = coalesce(
      ((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'tv')::int, 0)
$function$;

-- 4) RPC (public, SECURITY DEFINER, service_role 전용) --------------------------------

-- 4a) 새 family 발급(로그인/비번변경 후 현재기기). 현재 token_version 반환(access stamp 용).
create or replace function public.rt_issue(p_user uuid, p_token_hash text, p_user_agent text default null)
returns integer language plpgsql security definer set search_path to '' as $function$
declare v_tv integer;
begin
  insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
  values (p_user, p_token_hash, gen_random_uuid(),
          now() + interval '30 days', now() + interval '90 days', p_user_agent);
  select u.token_version into v_tv from public.users u where u.id = p_user;
  return coalesce(v_tv, 0);
end $function$;

-- 4b) 회전 + grace 유예. 결과 코드 + user_id + 현재 token_version 반환.
--     rotated: 정상 회전 / grace: 유실 재시도 재발급 / reuse_revoked: 탈취(family 회수)
--     invalid|expired|inactive: 발급 거부.
create or replace function public.rt_rotate(
  p_old_hash text, p_new_hash text, p_user_agent text default null, p_grace_seconds integer default 30)
returns table(result text, user_id uuid, token_version integer)
language plpgsql security definer set search_path to '' as $function$
declare r app.refresh_tokens; v_now timestamptz := now(); v_aff int; v_tv int;
begin
  select * into r from app.refresh_tokens where token_hash = p_old_hash;
  if not found then return query select 'invalid', null::uuid, null::int; return; end if;

  if not exists (select 1 from public.users u where u.id = r.user_id and u.status='active') then
    update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
      where family_id = r.family_id and revoked_at is null;
    return query select 'inactive', r.user_id, null::int; return;
  end if;
  if v_now > r.absolute_expires_at or v_now > r.expires_at then
    return query select 'expired', r.user_id, null::int; return;
  end if;

  if r.revoked_at is null then
    update app.refresh_tokens set revoked_at = v_now where id = r.id and revoked_at is null;
    get diagnostics v_aff = row_count;
    if v_aff > 0 then
      insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
      values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent);
      update app.refresh_tokens set replaced_by = (select id from app.refresh_tokens where token_hash = p_new_hash)
        where id = r.id;
      select u.token_version into v_tv from public.users u where u.id = r.user_id;
      return query select 'rotated', r.user_id, coalesce(v_tv,0); return;
    end if;
    -- v_aff=0: 동시 회전됨 → 아래 grace 판정으로
    select * into r from app.refresh_tokens where id = r.id;
  end if;

  -- 여기 도달 = 이미 revoked (유실 재시도 or 탈취)
  if v_now - r.revoked_at <= make_interval(secs => p_grace_seconds) then
    insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
    values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent);
    select token_version into v_tv from public.users where id = r.user_id;
    return query select 'grace', r.user_id, coalesce(v_tv,0); return;
  else
    update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
      where family_id = r.family_id and revoked_at is null;
    return query select 'reuse_revoked', r.user_id, null::int; return;
  end if;
end $function$;

-- 4c) 로그아웃: 해당 토큰의 family 전체 회수(멱등).
create or replace function public.rt_revoke_family(p_hash text)
returns void language sql security definer set search_path to '' as $function$
  update app.refresh_tokens set revoked_at = now()
   where family_id = (select family_id from app.refresh_tokens where token_hash = p_hash)
     and revoked_at is null;
$function$;

-- 4d) 사용자 전체 refresh 회수(비번변경/정지 시 타 기기 로그아웃).
create or replace function public.rt_revoke_user(p_user uuid)
returns void language sql security definer set search_path to '' as $function$
  update app.refresh_tokens set revoked_at = now() where user_id = p_user and revoked_at is null;
$function$;

-- 4e) 세션 epoch bump(전체 access 즉시 무효). 새 값 반환.
create or replace function public.bump_token_version(p_user uuid)
returns integer language sql security definer set search_path to '' as $function$
  update public.users set token_version = token_version + 1 where id = p_user returning token_version;
$function$;

-- 4f) 엣지용 비번변경(uid 명시). change_password 와 동일 검증이나 app.uid 대신 인자 사용.
create or replace function public.change_password_svc(p_user uuid, p_current text, p_new text)
returns void language plpgsql security definer set search_path to '' as $function$
begin
  if p_user is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  if p_new is null or length(p_new) < 6 then raise exception 'weak_password' using errcode='P0001'; end if;
  if not exists (
    select 1 from public.users
    where id = p_user and password_hash = extensions.crypt(p_current, password_hash)
  ) then raise exception 'invalid_current' using errcode='P0001'; end if;
  update public.users
     set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 12))
   where id = p_user;
end $function$;

-- 5) 권한: 위 RPC 는 service_role 만(엣지). PUBLIC 기본 EXECUTE 회수.
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.rt_issue(uuid,text,text)',
    'public.rt_rotate(text,text,text,integer)',
    'public.rt_revoke_family(text)',
    'public.rt_revoke_user(uuid)',
    'public.bump_token_version(uuid)',
    'public.change_password_svc(uuid,text,text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end $$;
