-- 채팅 푸시: 채팅 메시지 insert 시 수신자(발신자 제외 룸 멤버)에게 'chat_message' 알림 생성.
-- 기존 tg_chat_messages_after_insert(룸 last_message/미읽음 갱신)에 알림 insert 를 더한다.
-- 생성된 알림은 push 파이프라인(trg_notifications_push → send-push)으로 자동 발송되며,
-- notification_preferences.chat_message=false 인 사용자는 발송기에서 스킵된다.
create or replace function app.tg_chat_messages_after_insert()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare v_preview text;
begin
  if new.content is not null then v_preview := left(new.content, 100);
  else v_preview := '[사진]'; end if;

  update public.chat_rooms
     set last_message_id = new.id, last_message_at = new.created_at, last_message_preview = v_preview
   where id = new.room_id;

  -- 발신자 제외 멤버 미읽음 +1
  update public.users u
     set unread_chat_count = unread_chat_count + 1
    from public.chat_room_members m
   where m.room_id = new.room_id and m.user_id = u.id and m.user_id <> new.sender_id;

  -- 발신자 제외 멤버에게 채팅 알림(→ push). 발신자 닉네임 제목, 미리보기 본문.
  insert into public.notifications(
    user_id, actor_user_id, notification_type, title, body, resource_type, resource_id
  )
  select m.user_id, new.sender_id, 'chat_message',
         coalesce(su.nickname, '새 메시지'), v_preview, 'chat_room', new.room_id
    from public.chat_room_members m
    left join public.users su on su.id = new.sender_id
   where m.room_id = new.room_id and m.user_id <> new.sender_id;

  return new;
end;
$function$;
