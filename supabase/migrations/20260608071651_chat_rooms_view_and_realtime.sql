-- 채팅방 목록 뷰: 내가 속한 방 + 상대 닉네임 + 마지막 메시지 + 안 읽은 수.
-- security_invoker → 호출자(authenticated) RLS 적용, app.uid() = JWT sub.
-- (이후 20260608072435 에서 admin_inquiry 라벨 처리로 재정의됨)
create or replace view public.v_chat_rooms
with (security_invoker = true) as
select
  r.id,
  r.last_message_preview,
  r.last_message_at,
  (select pr.nickname
     from public.chat_room_members m2
     join public.public_profiles pr on pr.id = m2.user_id
    where m2.room_id = r.id and m2.user_id <> app.uid()
    limit 1) as other_nickname,
  (select m2.user_id
     from public.chat_room_members m2
    where m2.room_id = r.id and m2.user_id <> app.uid()
    limit 1) as other_user_id,
  (select count(*)
     from public.chat_messages cm
    where cm.room_id = r.id
      and cm.is_deleted = false
      and cm.sender_id <> app.uid()
      and (m.last_read_message_id is null
           or cm.created_at > (select lr.created_at
                                 from public.chat_messages lr
                                where lr.id = m.last_read_message_id))
  ) as unread_count
from public.chat_room_members m
join public.chat_rooms r on r.id = m.room_id
where m.user_id = app.uid();

grant select on public.v_chat_rooms to anon, authenticated;

-- 실시간 메시지 수신: chat_messages 를 realtime publication 에 추가.
alter publication supabase_realtime add table public.chat_messages;
