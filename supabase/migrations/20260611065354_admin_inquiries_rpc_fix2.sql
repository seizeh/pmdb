-- fix: last_message_preview(varchar) → text 캐스팅 (반환 타입 일치).
create or replace function public.admin_list_inquiries()
returns table (room_id uuid, user_id uuid, user_nickname text, last_message text, last_message_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select r.id, inq.user_id, coalesce(u.nickname,'알 수 없음')::text,
         r.last_message_preview::text, r.last_message_at
  from public.chat_rooms r
  left join lateral (
    select m.user_id from public.chat_room_members m
    join public.users uu on uu.id = m.user_id
    where m.room_id = r.id and uu.user_type <> 'admin'
    limit 1
  ) inq on true
  left join public.users u on u.id = inq.user_id
  where r.room_type = 'admin_inquiry'
  order by r.last_message_at desc nulls last;
end;
$function$;
