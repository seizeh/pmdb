-- 회원 탈퇴 + 가입 동의 기록 (법률 문서 정합 작업 후속).
-- ① users 에 동의 기록 컬럼(terms_agreed_at / marketing_opt_in) 추가, status 에 'deleted' 허용
-- ② signup_user 에 마케팅 동의 파라미터 추가(약관 동의 시각 기록)
-- ③ withdraw_account(): 개인정보 즉시 익명화(파기) + 세션 무효화 + 관계 데이터 정리.
--    부정이용 방지 최소 정보(아이디·전화번호)는 withdrawn_users 에 30일 분리 보관 후
--    pg_cron 으로 자동 파기 (개인정보 처리방침 §3 과 일치).

-- 1) 동의 기록 컬럼
alter table public.users add column if not exists terms_agreed_at timestamptz;
alter table public.users add column if not exists marketing_opt_in boolean not null default false;
alter table public.users add column if not exists marketing_opt_in_at timestamptz;

-- status 에 'deleted' 추가 (탈퇴 계정 — app.uid() 의 active 게이트로 즉시 세션 차단)
alter table public.users drop constraint if exists users_status_check;
alter table public.users add constraint users_status_check
  check (status in ('active','inactive','suspended','deleted'));

-- 2) signup_user — 마케팅 동의 파라미터 + 동의 시각 기록
drop function if exists public.signup_user(text, text, text, text, text);

create or replace function public.signup_user(
  p_username  text,
  p_password  text,
  p_nickname  text,
  p_user_type text,
  p_phone     text,
  p_marketing boolean default false
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

  -- 3) INSERT (비밀번호는 DB 에서 bcrypt 해싱, 필수 약관 동의 시각 기록)
  insert into public.users (
    username, password_hash, nickname, user_type, phone, phone_verified,
    terms_agreed_at, marketing_opt_in, marketing_opt_in_at
  ) values (
    p_username,
    extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
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
$$;

revoke all on function public.signup_user(text, text, text, text, text, boolean) from public;
revoke all on function public.signup_user(text, text, text, text, text, boolean) from anon;
revoke all on function public.signup_user(text, text, text, text, text, boolean) from authenticated;

-- 3) 탈퇴 시 부정이용 방지 분리보관 (30일 후 자동 파기)
create table if not exists app.withdrawn_users (
  user_id      uuid primary key,
  username     text,
  phone        text,
  withdrawn_at timestamptz not null default now()
);
alter table app.withdrawn_users enable row level security; -- 정책 없음 = definer 외 접근 불가

-- 30일 경과분 매일 새벽 파기
do $$ begin
  if exists (select 1 from cron.job where jobname = 'withdrawn-users-purge') then
    perform cron.unschedule('withdrawn-users-purge');
  end if;
end $$;
select cron.schedule('withdrawn-users-purge', '43 3 * * *',
  $$delete from app.withdrawn_users where withdrawn_at < now() - interval '30 days';$$);

-- 4) 회원 탈퇴 RPC — 개인정보 즉시 익명화 + 세션 무효화 + 관계 데이터 정리.
--    게시물·채팅 이력은 잔존하되 작성자는 익명 닉네임으로 표시(이용약관 제9조 ④).
create or replace function public.withdraw_account()
returns void language plpgsql security definer set search_path to '' as $function$
declare
  v_me uuid := app.uid();
  v_tag text;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  v_tag := substr(replace(v_me::text, '-', ''), 1, 10);

  -- 부정이용 방지 분리보관 (아이디·전화번호, 30일 후 cron 파기)
  insert into app.withdrawn_users (user_id, username, phone)
  select u.id, u.username, u.phone from public.users u where u.id = v_me
  on conflict (user_id) do nothing;

  -- 개인정보 익명화 + 상태 전환(token_version 증가 + status 변경 → 모든 세션 즉시 무효)
  update public.users set
    username = 'del_' || v_tag,
    nickname = '탈퇴회원' || v_tag,
    password_hash = '!',
    phone = null,
    phone_verified = false,
    profile_image_url = null,
    profile_image_thumbnail_url = null,
    profile_image_mime_type = null,
    profile_image_file_size = null,
    address = null,
    latitude = null,
    longitude = null,
    is_location_verified = false,
    region_code = null,
    activity_radius_m = null,
    push_enabled = false,
    marketing_opt_in = false,
    unread_notification_count = 0,
    unread_chat_count = 0,
    status = 'deleted',
    deleted_at = now(),
    token_version = token_version + 1
  where id = v_me and status = 'active';
  if not found then
    raise exception 'not_active_account' using errcode = 'P0001';
  end if;

  -- 세션·푸시·알림 정리
  delete from app.refresh_tokens where user_id = v_me;
  delete from public.device_tokens where user_id = v_me;
  delete from public.notifications where user_id = v_me;
  delete from public.notification_preferences where user_id = v_me;

  -- 소셜 관계 정리 (팔로우 양방향)
  delete from public.pawings where follower_id = v_me or following_id = v_me;

  -- 반려동물: 내가 대표 보호자인 펫은 삭제 처리, 내 보호자 멤버십 제거
  update public.pets set pet_status = 'deleted', updated_at = now()
   where primary_guardian_id = v_me and pet_status <> 'deleted';
  delete from public.pet_guardians where user_id = v_me;

  -- 채팅: 모든 방에서 나가기(목록 숨김 · 상대는 전송 불가 안내)
  update public.chat_room_members set left_at = now(), updated_at = now()
   where user_id = v_me and left_at is null;
end $function$;

revoke all on function public.withdraw_account() from public, anon;
grant execute on function public.withdraw_account() to authenticated;
