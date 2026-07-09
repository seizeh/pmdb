-- 비밀번호 해싱을 bcrypt(pgcrypto) → argon2id(엣지펑션 해싱)로 전환.
--
-- 배경: 개인정보 처리방침(§7)이 argon2id 를 명시하나 실제 구현은 bcrypt 였다.
-- pgcrypto 에는 argon2 가 없으므로 해싱·검증을 엣지펑션(Deno, hash-wasm)으로 옮기고,
-- DB 는 해시 문자열 보관/원자적 갱신만 담당한다. 평문 비밀번호가 SQL 계층에
-- 도달하지 않게 되는 부수 효과(로그·pg_stat_statements 노출 차단)도 있다.
--
-- 기존 bcrypt($2a$…) 해시는 그대로 두고, 엣지가 접두사로 구분해 이중 검증한다.
-- bcrypt 사용자가 로그인 성공하면 그 자리에서 argon2id 로 재해싱(점진 전환) —
-- 강제 로그아웃/재설정 없음.
--
-- 함수 시그니처 변경(전부 service_role 전용, 엣지에서만 호출):
--   signup_user(…, p_password)        → signup_user(…, p_password_hash)
--   login_user(username, password)    → get_login_user(username)  + update_password_hash(CAS)
--   change_password_and_rotate(…)     → p_current/p_new → p_current_hash(CAS)/p_new_hash
--   reset_password_user(phone, pw)    → reset_password_user(phone, p_new_hash)
-- 드롭(평문 경로 제거): login_user, change_password(레거시 직접 RPC),
--   change_password_svc, app._set_password

-- 1) 로그인용 사용자 조회 — 비번 검증은 엣지에서. status='active' 만 반환(기존과 동일).
drop function if exists public.get_login_user(text);
create function public.get_login_user(p_username text)
returns table(id uuid, username text, nickname text, user_type text, password_hash text)
language sql
security definer
set search_path to ''
as $function$
  select u.id, u.username::text, u.nickname::text, u.user_type::text, u.password_hash::text
  from public.users u
  where lower(u.username) = lower(p_username)
    and u.status = 'active';
$function$;

-- 2) 점진 재해싱(bcrypt → argon2id) — CAS: 조회 시점 해시와 일치할 때만 교체
--    (동시 비번변경과의 레이스 방지). 세션 무효화 없음(비번 자체는 동일).
drop function if exists public.update_password_hash(uuid, text, text);
create function public.update_password_hash(p_user uuid, p_old_hash text, p_new_hash text)
returns boolean
language sql
security definer
set search_path to ''
as $function$
  update public.users set password_hash = p_new_hash
  where id = p_user and password_hash = p_old_hash
  returning true;
$function$;

-- 3) 비밀번호 변경용 현재 해시 조회 (change-password 엣지가 현재 비번 검증에 사용)
drop function if exists public.get_password_hash(uuid);
create function public.get_password_hash(p_user uuid)
returns text
language sql
security definer
set search_path to ''
as $function$
  select u.password_hash::text from public.users u
  where u.id = p_user and u.status = 'active';
$function$;

-- 4) change_password_and_rotate — 평문 대신 해시를 받는다.
--    p_current_hash 는 엣지가 검증에 사용한 해시 그대로(CAS 토큰) → 검증~갱신 사이에
--    다른 세션이 비번을 바꿨으면 0행 = invalid_current 로 전체 롤백.
drop function if exists public.change_password_and_rotate(uuid, text, text, integer, text, text);
create function public.change_password_and_rotate(
  p_user uuid,
  p_current_hash text,
  p_new_hash text,
  p_tv integer,
  p_new_token_hash text,
  p_user_agent text default null
) returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare v_tv integer;
begin
  if p_user is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- 세션 유효성(정지/전역 무효화 반영) — app.uid 게이트와 동일 기준.
  if not exists (
    select 1 from public.users
    where id = p_user and status = 'active' and token_version = coalesce(p_tv, 0)
  ) then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- 비번 갱신(CAS). 0행이면 검증 시점과 해시가 달라진 것 → invalid_current 로 롤백.
  update public.users set password_hash = p_new_hash
   where id = p_user and password_hash = p_current_hash;
  if not found then
    raise exception 'invalid_current' using errcode = 'P0001';
  end if;

  -- 전 세션 무효화: token_version bump + 모든 refresh 회수
  update public.users set token_version = token_version + 1
   where id = p_user
   returning token_version into v_tv;
  update app.refresh_tokens set revoked_at = now()
   where user_id = p_user and revoked_at is null;

  -- 현재 기기용 새 refresh family 발급
  insert into app.refresh_tokens(
    user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent
  ) values (
    p_user, p_new_token_hash, gen_random_uuid(),
    now() + interval '30 days', now() + interval '90 days', p_user_agent
  );

  return v_tv;
end;
$function$;

-- 5) reset_password_user — 해시를 받는다(비번 정책 검증은 엣지에서, 기존에도 수행).
drop function if exists public.reset_password_user(text, text);
create function public.reset_password_user(p_phone text, p_new_hash text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id uuid;
begin
  -- 전화 인증 완료 확인(password_reset 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'password_reset'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  select id into v_id from public.users where phone = p_phone;
  if v_id is null then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  -- 비번 갱신 + 전 세션 무효화(token_version bump + refresh 전량 회수)
  update public.users
     set password_hash = p_new_hash,
         token_version = token_version + 1
   where id = v_id;
  update app.refresh_tokens set revoked_at = now()
   where user_id = v_id and revoked_at is null;

  return v_id;
end;
$function$;

-- 6) signup_user — 해시를 받는다(입력·정책 검증은 signup 엣지에서, 기존에도 수행).
drop function if exists public.signup_user(text, text, text, text, text, boolean);
create function public.signup_user(
  p_username      text,
  p_password_hash text,
  p_nickname      text,
  p_user_type     text,
  p_phone         text,
  p_marketing     boolean default false
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
begin
  -- 1) 전화 인증 완료 확인 (signup 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'signup'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  -- 2) 중복 사전 검사 (유니크 인덱스가 최종 방어선, 여기선 친절한 에러코드용)
  if exists (select 1 from public.users where lower(username) = lower(p_username)) then
    raise exception 'username_taken' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.users where lower(nickname) = lower(p_nickname)) then
    raise exception 'nickname_taken' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.users where phone = p_phone) then
    raise exception 'phone_taken' using errcode = 'P0001';
  end if;

  -- 3) INSERT (해시는 엣지에서 argon2id 로 생성, 필수 약관 동의 시각 기록)
  insert into public.users (
    username, password_hash, nickname, user_type, phone, phone_verified,
    terms_agreed_at, marketing_opt_in, marketing_opt_in_at
  ) values (
    p_username,
    p_password_hash,
    p_nickname,
    p_user_type,
    p_phone,
    true,
    now(),
    coalesce(p_marketing, false),
    case when coalesce(p_marketing, false) then now() else null end
  )
  returning id into v_id;

  return v_id;
end;
$function$;

-- 7) 평문 비밀번호를 받던 레거시 RPC 제거 (현재 앱은 전부 엣지펑션 경유)
drop function if exists public.login_user(text, text);
drop function if exists public.change_password(text, text);
drop function if exists public.change_password_svc(uuid, text, text, integer);
drop function if exists app._set_password(uuid, text, text);

-- 8) 권한: 전부 엣지 전용(service_role). PUBLIC 기본 EXECUTE 회수.
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.get_login_user(text)',
    'public.update_password_hash(uuid,text,text)',
    'public.get_password_hash(uuid)',
    'public.change_password_and_rotate(uuid,text,text,integer,text,text)',
    'public.reset_password_user(text,text)',
    'public.signup_user(text,text,text,text,text,boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end $$;
