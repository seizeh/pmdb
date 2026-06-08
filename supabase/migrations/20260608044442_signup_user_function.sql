-- 회원가입: 비밀번호를 pgcrypto(bcrypt)로 해싱해 users INSERT.
-- SECURITY DEFINER + service_role 전용 실행권한 → 클라이언트(anon) 직접 호출 불가.
-- 전화 인증(verify-phone-code 로 is_used=true)이 30분 내 완료된 번호만 가입 허용.
create or replace function public.signup_user(
  p_username  text,
  p_password  text,
  p_nickname  text,
  p_user_type text,
  p_phone     text
) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
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

  -- 3) INSERT (비밀번호는 DB 에서 bcrypt 해싱)
  insert into public.users (
    username, password_hash, nickname, user_type, phone, phone_verified
  ) values (
    p_username,
    extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
    p_nickname,
    p_user_type,
    p_phone,
    true
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- 실행권한: 클라이언트 역할에서 회수하고 service_role(Edge Function) 에게만 부여
revoke all on function public.signup_user(text, text, text, text, text) from public;
revoke all on function public.signup_user(text, text, text, text, text) from anon;
revoke all on function public.signup_user(text, text, text, text, text) from authenticated;
grant execute on function public.signup_user(text, text, text, text, text) to service_role;
