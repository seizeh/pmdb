-- 채팅 메시지 삭제(본인 것만) — SECURITY DEFINER RPC.
-- chat_messages UPDATE RLS 는 admin 전용이라 클라이언트 직접 UPDATE 불가 →
-- 정의자 RPC 로 소프트 삭제. 함께 처리:
--  · 안 읽은 멤버의 unread_chat_count -1 보정(카운터 드리프트 방지)
--  · 방 미리보기(last_message_*)가 이 메시지면 최신 비삭제 메시지로 갱신

create or replace function public.delete_my_chat_message(p_message uuid)
returns void
language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_msg public.chat_messages%rowtype;
  v_next_id uuid;
  v_next_at timestamptz;
  v_next_preview text;
begin
  if v_uid is null then raise exception 'chat: 로그인이 필요합니다'; end if;

  select * into v_msg from public.chat_messages where id = p_message;
  if not found or v_msg.sender_id <> v_uid then
    raise exception 'chat: 내가 보낸 메시지만 삭제할 수 있어요';
  end if;
  if v_msg.is_deleted then return; end if;

  update public.chat_messages set is_deleted = true where id = p_message;

  -- 아직 이 메시지를 읽지 않은 멤버의 미읽음 카운터 보정.
  update public.users u
     set unread_chat_count = greatest(u.unread_chat_count - 1, 0)
    from public.chat_room_members m
   where m.room_id = v_msg.room_id
     and m.user_id = u.id
     and m.user_id <> v_uid
     and (m.last_read_message_id is null
          or v_msg.created_at > (select lr.created_at
                                   from public.chat_messages lr
                                  where lr.id = m.last_read_message_id));

  -- 방 목록 미리보기가 이 메시지였다면 다음 최신 메시지로.
  if (select last_message_id from public.chat_rooms where id = v_msg.room_id)
     = p_message then
    select m.id, m.created_at,
           case when m.content is not null then left(m.content, 100)
                else '[사진]' end
      into v_next_id, v_next_at, v_next_preview
      from public.chat_messages m
     where m.room_id = v_msg.room_id and m.is_deleted = false
     order by m.created_at desc limit 1;
    update public.chat_rooms
       set last_message_id = v_next_id,
           last_message_at = coalesce(v_next_at, last_message_at),
           last_message_preview = coalesce(v_next_preview, '삭제된 메시지')
     where id = v_msg.room_id;
  end if;
end;
$function$;

grant execute on function public.delete_my_chat_message(uuid) to authenticated;
