-- 내 게시글 수정(제목/내용/약속일정) + 일정 변경 시 진행 중 지원자에게 알림.
--
-- 편집은 소프트삭제와 달리 행이 계속 SELECT 가시라 직접 UPDATE 도 가능하지만,
-- '일정 변경 → 지원자(타 사용자) 알림 insert'는 RLS 상 클라이언트가 못 하므로
-- 소유자 검증 후 알림까지 원자적으로 처리하는 SECURITY DEFINER RPC 로 통일한다.
-- 알림은 notifications insert → 기존 트리거(app.on_notification_push)가 자동 푸시.

-- 1) 새 알림 타입 'schedule_changed' 를 CHECK 제약에 추가(없으면 트리거가 조용히 실패).
alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (notification_type in (
    'chat_message','post_application','post_comment','pawing_new_post',
    'application_accepted','application_accepted_by_co','review_received',
    'guardian_invite','system_notice','location_expired','chat_read_receipt',
    'unread_sync','security_login','schedule_changed'
  ));

-- 2) 내 게시글 수정 RPC. 제목/내용/약속일정만 변경(카테고리/사진/펫은 재검증 필요 → 제외).
create or replace function public.update_my_post(
  p_post uuid,
  p_title text,
  p_content text,
  p_scheduled_at timestamptz default null
) returns void
language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_owner uuid;
  v_old_sched timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_content), '') = '' then
    raise exception 'posts: 제목과 내용을 입력해주세요';
  end if;

  select user_id, scheduled_at into v_owner, v_old_sched
  from public.posts
  where id = p_post
  for update;

  if v_owner is null then
    raise exception 'post_not_found';
  end if;
  if v_owner <> v_uid then
    raise exception 'not_owner';
  end if;

  update public.posts
     set title = btrim(p_title),
         content = btrim(p_content),
         scheduled_at = p_scheduled_at
   where id = p_post;

  -- 약속 일정이 실제로 바뀌었고 새 일정이 있으면, 진행 중(대기/수락) 지원자에게 알림.
  if v_old_sched is distinct from p_scheduled_at and p_scheduled_at is not null then
    insert into public.notifications(
      user_id, actor_user_id, notification_type, title, body, resource_type, resource_id
    )
    select a.applicant_id,
           v_uid,
           'schedule_changed',
           '약속 일정이 변경됐어요',
           btrim(p_title) || ' — '
             || to_char(p_scheduled_at at time zone 'Asia/Seoul', 'MM월 DD일 HH24시') || ' 로 변경',
           'post',
           p_post
    from public.applications a
    where a.post_id = p_post
      and a.status in ('pending', 'accepted');
  end if;
end $function$;

grant execute on function public.update_my_post(uuid, text, text, timestamptz) to authenticated;
