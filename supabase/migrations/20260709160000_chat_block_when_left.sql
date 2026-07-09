-- 나간 채팅방 잠금: 한쪽이 나간(left_at) 방에는 누구도 새 메시지를 보낼 수 없다.
-- 나간 사람이 start_direct_chat 으로 다시 참여해야 전송이 풀린다.
-- (이 정책으로 "새 메시지 시 자동 재입장" 트리거는 도달 불가능해져 제거.)

-- 1) 자동 재입장 트리거 제거 (메시지가 차단되므로 무의미)
drop trigger if exists trg_chat_messages_rejoin on public.chat_messages;
drop function if exists app.chat_rejoin_on_message();

-- 2) 전송 차단 — 방 멤버 중 나간 사람이 있으면 INSERT 거부
create or replace function app.chat_block_left_room()
returns trigger language plpgsql security definer set search_path to '' as $function$
begin
  if exists (
    select 1 from public.chat_room_members m
    where m.room_id = new.room_id and m.left_at is not null
  ) then
    raise exception '상대가 채팅방을 나가 메시지를 보낼 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $function$;

drop trigger if exists trg_chat_messages_block_left on public.chat_messages;
create trigger trg_chat_messages_block_left
  before insert on public.chat_messages
  for each row execute function app.chat_block_left_room();

-- 3) 채팅 목록 뷰 — 상대가 나갔는지(other_left) 노출해 앱이 입력창을 잠글 수 있게.
--    (뷰 컬럼은 끝에만 추가 가능하므로 마지막에 덧붙인다.)
create or replace view public.v_chat_rooms with (security_invoker = true) as
select r.id,
    r.last_message_preview,
    r.last_message_at,
    coalesce((
        select pr.nickname::text
        from public.chat_room_members m2
        join public.public_profiles pr on pr.id = m2.user_id
        join public.users u2 on u2.id = m2.user_id
        where m2.room_id = r.id
          and m2.user_id <> app.uid()
          and (r.room_type::text <> 'admin_inquiry' or u2.user_type::text <> 'admin')
        limit 1),
        case when r.room_type::text = 'admin_inquiry' then '고객센터' else '알 수 없음' end
    ) as other_nickname,
    (
        select m2.user_id
        from public.chat_room_members m2
        join public.users u2 on u2.id = m2.user_id
        where m2.room_id = r.id
          and m2.user_id <> app.uid()
          and (r.room_type::text <> 'admin_inquiry' or u2.user_type::text <> 'admin')
        limit 1
    ) as other_user_id,
    (
        select count(*)
        from public.chat_messages cm
        where cm.room_id = r.id
          and cm.is_deleted = false
          and cm.sender_id <> app.uid()
          and (m.last_read_message_id is null
               or cm.created_at > (select lr.created_at from public.chat_messages lr
                                   where lr.id = m.last_read_message_id))
    ) as unread_count,
    exists (
        select 1 from public.chat_room_members m3
        where m3.room_id = r.id
          and m3.user_id <> app.uid()
          and m3.left_at is not null
    ) as other_left
from public.chat_room_members m
join public.chat_rooms r on r.id = m.room_id
where m.user_id = app.uid()
  and m.left_at is null;
