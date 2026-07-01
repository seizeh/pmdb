-- 비밀번호 재설정: 전화 OTP(password_reset) 인증 완료(30분 내)된 번호로 사용자 찾아 비번 갱신.
-- signup_user 와 동일 패턴(SECURITY DEFINER + service_role 전용). 로그인 전 단계라 app.uid 없음 →
-- 번호(users.phone 평문)로 사용자를 특정한다. 재설정 시 token_version bump + refresh 전량 회수
-- 로 기존 모든 세션을 무효화한다.
create or replace function public.reset_password_user(p_phone text, p_new_password text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_id uuid;
begin
  -- 1) 비번 정책(signup 과 동일: 영문+숫자 8자 이상)
  if p_new_password is null or length(p_new_password) < 8
     or p_new_password !~ '[A-Za-z]' or p_new_password !~ '[0-9]' then
    raise exception 'invalid_password' using errcode = 'P0001';
  end if;

  -- 2) 전화 인증 완료 확인(password_reset 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'password_reset'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  -- 3) 번호로 사용자 조회
  select id into v_id from public.users where phone = p_phone;
  if v_id is null then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  -- 4) 비번 갱신 + 전 세션 무효화(token_version bump + refresh 전량 회수)
  update public.users
     set password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf', 12)),
         token_version = token_version + 1
   where id = v_id;
  update app.refresh_tokens set revoked_at = now()
   where user_id = v_id and revoked_at is null;

  return v_id;
end;
$$;

revoke all on function public.reset_password_user(text, text) from public, anon, authenticated;
grant execute on function public.reset_password_user(text, text) to service_role;
