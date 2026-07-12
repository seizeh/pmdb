-- 전체 공지 발송 RPC (약관·처리방침 개정 고지 등).
-- 약관 제3조③·처리방침 §14가 약속한 "개정 7일(불리 변경 30일) 전 고지"의 실행 수단.
-- system_notice 알림을 탈퇴자를 제외한 전 회원에게 1행씩 insert 하면 기존 파이프라인이
-- 나머지를 처리한다: trg_notifications_push → send-push 엣지(수신 설정·기기 토큰 반영),
-- trg_notifications_unread_count → 미읽음 배지. is_admin 게이트 SECURITY DEFINER 컨벤션.
create or replace function public.admin_broadcast_system_notice(
  p_title text,
  p_body  text
) returns integer
language plpgsql security definer set search_path to ''
as $function$
declare
  v_cnt int;
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if p_title is null or length(btrim(p_title)) = 0 or length(p_title) > 80 then
    raise exception 'invalid_title' using errcode='P0001';
  end if;
  if p_body is null or length(btrim(p_body)) = 0 or length(p_body) > 1000 then
    raise exception 'invalid_body' using errcode='P0001';
  end if;

  -- 정지(suspended)·휴면(inactive) 회원도 약관 개정 고지 대상 — 탈퇴자만 제외.
  insert into public.notifications (user_id, notification_type, is_system, title, body)
  select u.id, 'system_notice', true, btrim(p_title), btrim(p_body)
    from public.users u
   where u.status <> 'deleted';
  get diagnostics v_cnt = row_count;

  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'broadcast_system_notice', 'system', null,
          jsonb_build_object('title', btrim(p_title), 'recipients', v_cnt));

  return v_cnt;
end $function$;

revoke all on function public.admin_broadcast_system_notice(text, text) from public, anon;
grant execute on function public.admin_broadcast_system_notice(text, text) to authenticated;
