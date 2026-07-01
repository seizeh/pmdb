-- 새 기기 로그인 인앱 알림: 다른 활성 세션이 있는 상태로 새 기기가 로그인하면
-- 본인에게 'security_login' 알림을 남긴다(보안 인지용). OS 푸시 인프라(FCM/APNs)는 미구축
-- 이라 인앱 알림(notifications 테이블)만. device_tokens/push_* 컬럼은 향후 푸시 연동 여지.

-- notification_type CHECK 에 'security_login' 추가(새 타입은 CHECK 도 같이 수정해야 트리거가
-- 조용히 삼키지 않음).
alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (notification_type::text = any (array[
    'chat_message','post_application','post_comment','pawing_new_post',
    'application_accepted','application_accepted_by_co','review_received',
    'guardian_invite','system_notice','location_expired','chat_read_receipt',
    'unread_sync','security_login'
  ]::text[]));

-- login 전용: 새 refresh family 발급 + (다른 활성 세션이 있었으면) 로그인 알림. token_version 반환.
-- rt_issue 를 대체(login 만 사용). service_role 전용.
create or replace function public.login_issue_refresh(
  p_user uuid, p_token_hash text, p_user_agent text default null
) returns integer
language plpgsql security definer set search_path to '' as $function$
declare v_had_other boolean; v_tv integer;
begin
  -- 새 세션 발급 전, 이미 활성 세션(다른 기기)이 있는지 확인
  select exists(
    select 1 from app.refresh_tokens
    where user_id = p_user and revoked_at is null and expires_at > now()
  ) into v_had_other;

  insert into app.refresh_tokens(
    user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent
  ) values (
    p_user, p_token_hash, gen_random_uuid(),
    now() + interval '30 days', now() + interval '90 days', p_user_agent
  );

  if v_had_other then
    insert into public.notifications(user_id, notification_type, is_system, title, body)
    values (p_user, 'security_login', true,
            '새 기기에서 로그인되었어요',
            '본인이 아니라면 비밀번호를 변경해주세요.');
  end if;

  select token_version into v_tv from public.users u where u.id = p_user;
  return coalesce(v_tv, 0);
end $function$;

revoke all on function public.login_issue_refresh(uuid, text, text) from public, anon, authenticated;
grant execute on function public.login_issue_refresh(uuid, text, text) to service_role;
