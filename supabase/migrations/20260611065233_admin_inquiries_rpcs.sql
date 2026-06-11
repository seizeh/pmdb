-- 관리자 문의(admin_inquiry 채팅방) 처리 RPC (is_admin 게이트).
-- 관리자는 문의방에 참여(chat_room_members)해야 답장 가능(RLS: 멤버만 전송).
create or replace function public.admin_list_inquiries()
returns table (room_id uuid, user_id uuid, user_nickname text, last_message text, last_message_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select r.id, inq.user_id, coalesce(u.nickname,'알 수 없음')::text,
         r.last_message_preview, r.last_message_at
  from public.chat_rooms r
  left join lateral (
    select m.user_id from public.chat_room_members m
    join public.users uu on uu.id = m.user_id
    where m.room_id = r.id and uu.user_type <> 'admin'
    order by m.created_at asc limit 1
  ) inq on true
  left join public.users u on u.id = inq.user_id
  where r.room_type = 'admin_inquiry'
  order by r.last_message_at desc nulls last;
end;
$function$;
grant execute on function public.admin_list_inquiries() to authenticated;

create or replace function public.admin_join_inquiry(p_room uuid)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists (select 1 from public.chat_rooms where id=p_room and room_type='admin_inquiry') then
    raise exception 'not_inquiry_room' using errcode='P0001';
  end if;
  insert into public.chat_room_members(room_id, user_id)
  values (p_room, app.uid())
  on conflict (room_id, user_id) do nothing;
end;
$function$;
grant execute on function public.admin_join_inquiry(uuid) to authenticated;
