-- 상대 멤버가 없는 admin_inquiry(고객센터) 방은 '고객센터'로 라벨링.
-- coalesce 로 컬럼 타입이 바뀌어 CREATE OR REPLACE 불가 → DROP 후 재생성.
drop view if exists public.v_chat_rooms;

create view public.v_chat_rooms
with (security_invoker = true) as
select
  r.id,
  r.last_message_preview,
  r.last_message_at,
  coalesce(
    (select pr.nickname::text
       from public.chat_room_members m2
       join public.public_profiles pr on pr.id = m2.user_id
      where m2.room_id = r.id and m2.user_id <> app.uid()
      limit 1),
    case when r.room_type = 'admin_inquiry' then '고객센터' else '알 수 없음' end
  ) as other_nickname,
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
