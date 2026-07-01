-- change-password 원자화(리뷰 minor #1): 엣지가 4개 RPC(change_password_svc/bump_token_version/
-- rt_revoke_user/rt_issue)를 순차 호출하던 것을 단일 트랜잭션 RPC 로 합친다. 중간 실패 시
-- 부분상태(비번만 바뀌고 세션 재발급 실패 등)가 남지 않도록 한 함수 = 한 트랜잭션으로 처리.
--
-- 세션 게이트(status + token_version) → 비번검증/갱신(코어 재사용) → token_version bump +
-- refresh 전량 회수 → 현재 기기용 새 family 발급. 새 access 서명용 token_version 반환.
-- (기존 change_password_svc/bump_token_version/rt_revoke_user 는 admin 등 재사용 여지가 있어 유지.)
create or replace function public.change_password_and_rotate(
  p_user uuid,
  p_current text,
  p_new text,
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

  -- 비번 검증 + 갱신(정책 코어 재사용: weak_password/invalid_current 여기서 raise → 전체 롤백)
  perform app._set_password(p_user, p_current, p_new);

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

revoke all on function public.change_password_and_rotate(uuid, text, text, integer, text, text)
  from public, anon, authenticated;
grant execute on function public.change_password_and_rotate(uuid, text, text, integer, text, text)
  to service_role;
