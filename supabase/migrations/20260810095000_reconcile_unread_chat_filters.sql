-- 채팅 미읽음 보정이 "화면에 없는 방" 까지 세던 문제.
--
-- ── 무엇이 어긋나 있었나 ────────────────────────────────────────────────
--
-- 화면의 방 목록은 v_chat_rooms 다. 이 뷰는 두 가지를 뺀다:
--
--     m.left_at is null                       -- 나간 방
--     and not exists (…user_blocks…)          -- 차단 관계인 상대와의 방
--
-- 그런데 app.reconcile_unread_counts 의 채팅 합산 루프는
--
--     select room_id, last_read_message_id
--       from public.chat_room_members
--      where user_id = v_user
--
-- 뿐이라 **둘 다 없다.** 즉 보정이 뷰보다 넓게 센다 — 화면엔 없는 방의 미읽음이
-- 배지에 더해진다.
--
-- 재발 경로가 구체적이다: 차단하면 트리거(20260803190000)가 카운터를 올바르게
-- 차감한다. 그런데 다음 로그인에서 reconcile 이 돌면서(#232 경로 — 로그인마다
-- 실행) 숨겨진 방의 미읽음을 도로 더한다. 사용자는 열 방이 없는데 배지가 남고,
-- 지워도 **로그인할 때마다 다시 붙는다.**
--
-- ⚠️ 현재 피해자는 0명이다(운영 실측: user_blocks 역대 0건, unread_chat_count>0
-- 인 사용자 0명). 소급 보정은 대상이 없다 — 잠복 결함을 닫는 것이다.
--
-- 나간 방(left_at) 쪽도 같은 성격이라 함께 막는다.
--
-- ── 주의 ────────────────────────────────────────────────────────────────
--
-- 차단 판정에 app.uid() 를 쓰면 안 된다. 이 함수는 관리자/시스템이 다른 사용자를
-- 대상으로도 부를 수 있고(그때 app.uid() 는 NULL 이거나 남의 것) 그러면 필터가
-- 조용히 빗나간다. 반드시 v_user 를 쓴다.
--
-- 알림 합산(2)에는 필터를 넣지 않는다 — 차단 상대의 알림은 애초에
-- trg_notifications_block_filter 가 만들지 않는다.
--
-- 나머지 본문은 현재 운영 정의와 같다.

create or replace function app.reconcile_unread_counts(p_user_id uuid default null::uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user     uuid;
  v_chat     int := 0;
  v_notif    int := 0;
  r          record;
  v_per      int;
  v_read_ts  timestamptz;
  v_read_id  uuid;
begin
  v_user := coalesce(p_user_id, app.uid());
  if v_user is null then
    raise exception 'reconcile_unread_counts: 대상 사용자가 지정되지 않았습니다';
  end if;

  -- 본인이 아닌 다른 사용자 대상 호출은 관리자/시스템(=app.uid() NULL) 한정
  if app.uid() is not null and app.uid() <> v_user and not app.is_admin() then
    raise exception 'reconcile_unread_counts: 본인 카운트만 보정할 수 있습니다';
  end if;

  -- (1) 미읽음 채팅 합계: 방별 last_read_message_id 기준 (created_at, id) 튜플 비교
  --     범위는 v_chat_rooms 와 같아야 한다 — 나간 방·차단 상대 방은 화면에 없다.
  for r in
    select m.room_id, m.last_read_message_id
      from public.chat_room_members m
     where m.user_id = v_user
       and m.left_at is null
       and not exists (
         select 1
           from public.chat_room_members other
           join public.user_blocks b
             on (b.blocker_id = v_user and b.blocked_id = other.user_id)
             or (b.blocked_id = v_user and b.blocker_id = other.user_id)
          where other.room_id = m.room_id
            and other.user_id <> v_user)
  loop
    if r.last_read_message_id is null then
      select count(*) into v_per
        from public.chat_messages msg
       where msg.room_id   = r.room_id
         and msg.sender_id <> v_user
         and msg.is_deleted = false;
    else
      select created_at, id into v_read_ts, v_read_id
        from public.chat_messages
       where id = r.last_read_message_id;
      select count(*) into v_per
        from public.chat_messages msg
       where msg.room_id   = r.room_id
         and msg.sender_id <> v_user
         and msg.is_deleted = false
         and (msg.created_at, msg.id) > (v_read_ts, v_read_id);
    end if;
    v_chat := v_chat + coalesce(v_per, 0);
  end loop;

  -- (2) 미읽음 알림 합계
  select count(*) into v_notif
    from public.notifications n
   where n.user_id = v_user and n.is_read = false;

  -- (3) 캐시 갱신
  update public.users
     set unread_chat_count         = v_chat,
         unread_notification_count = v_notif
   where id = v_user;
end;
$function$;

comment on function app.reconcile_unread_counts(uuid) is
  '미읽음 카운터 캐시 보정(로그인마다). 채팅 합산 범위는 v_chat_rooms 와 동일 — 나간 방·차단 상대 방 제외.';
