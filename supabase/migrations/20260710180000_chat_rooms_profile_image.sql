-- 채팅 목록에 상대 프로필 사진 노출 — 타일 블러 배경용 (뷰 끝에 컬럼 추가).
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
    (exists (
        select 1 from public.chat_room_members m3
        where m3.room_id = r.id and m3.user_id <> app.uid() and m3.left_at is not null
    )) as other_left,
    (
        select pr.profile_image_url
        from public.chat_room_members m2
        join public.public_profiles pr on pr.id = m2.user_id
        join public.users u2 on u2.id = m2.user_id
        where m2.room_id = r.id
          and m2.user_id <> app.uid()
          and (r.room_type::text <> 'admin_inquiry' or u2.user_type::text <> 'admin')
        limit 1
    ) as other_profile_image_url
from public.chat_room_members m
join public.chat_rooms r on r.id = m.room_id
where m.user_id = app.uid()
  and m.left_at is null;
