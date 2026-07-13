-- 고객센터(admin_inquiry) 방은 나갈 수 없게 — leave_chat_room 게이트.
-- 앱도 고객센터 방에선 메뉴(나가기)를 숨기지만, RPC 직접 호출 우회를 막는다.

create or replace function public.leave_chat_room(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $function$
declare
  v_me uuid := app.uid();
  v_last uuid;
  v_type text;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = 'P0001'; end if;

  select room_type::text, last_message_id into v_type, v_last
    from public.chat_rooms where id = p_room;
  if v_type = 'admin_inquiry' then
    raise exception '고객센터 채팅방은 나갈 수 없어요' using errcode = 'P0001';
  end if;

  update public.chat_room_members
     set left_at = now(),
         last_read_message_id = coalesce(v_last, last_read_message_id),
         updated_at = now()
   where room_id = p_room and user_id = v_me;
  if not found then raise exception 'not_a_member' using errcode = 'P0001'; end if;
end $function$;
