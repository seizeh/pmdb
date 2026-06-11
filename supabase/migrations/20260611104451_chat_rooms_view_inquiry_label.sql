-- admin_inquiry 방에서 상대(other)를 "관리자가 아닌 멤버"로 한정.
--  - 문의자 시점: 관리자만 상대로 남아 제외됨 → COALESCE 가 '고객센터' 로 채움(관리자 신원 비노출).
--  - 관리자 시점: 비관리자 멤버(=문의자)가 상대로 잡혀 문의자 닉네임 표시.
-- 그 외(direct) 방은 기존과 동일. security_invoker=true 보존.
create or replace view public.v_chat_rooms
with (security_invoker = true) as
 select r.id,
    r.last_message_preview,
    r.last_message_at,
    coalesce(
      ( select pr.nickname::text
        from chat_room_members m2
          join public_profiles pr on pr.id = m2.user_id
          join users u2 on u2.id = m2.user_id
        where m2.room_id = r.id
          and m2.user_id <> app.uid()
          and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
        limit 1),
      case when r.room_type::text = 'admin_inquiry'::text then '고객센터'::text else '알 수 없음'::text end
    ) as other_nickname,
    ( select m2.user_id
        from chat_room_members m2
          join users u2 on u2.id = m2.user_id
        where m2.room_id = r.id
          and m2.user_id <> app.uid()
          and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
        limit 1) as other_user_id,
    ( select count(*) as count
        from chat_messages cm
        where cm.room_id = r.id and cm.is_deleted = false and cm.sender_id <> app.uid()
          and (m.last_read_message_id is null or cm.created_at > ( select lr.created_at from chat_messages lr where lr.id = m.last_read_message_id))) as unread_count
   from chat_room_members m
     join chat_rooms r on r.id = m.room_id
  where m.user_id = app.uid();
