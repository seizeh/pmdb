-- 채팅방 나가기 (0033 후속): chat_room_members.left_at + 목록 제외 + 나가기 RPC.
-- 카카오식 동작: 나가면 내 목록에서만 사라지고, 그 방에 새 메시지가 오면
-- (또는 내가 다시 채팅을 시작하면) 다시 나타난다. 메시지 이력은 유지.

-- 1) 나간 시각(null = 참여 중)
alter table public.chat_room_members add column if not exists left_at timestamptz;

-- 2) 채팅 목록 뷰 — 나간 방 제외 (기존 정의 + m.left_at is null)
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
    ) as unread_count
from public.chat_room_members m
join public.chat_rooms r on r.id = m.room_id
where m.user_id = app.uid()
  and m.left_at is null;

-- 3) 나가기 RPC — 읽음 커서를 최신으로 옮겨(기존 읽음 트리거가 전역 unread 감산)
--    left_at 을 기록한다.
create or replace function public.leave_chat_room(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $function$
declare
  v_me uuid := app.uid();
  v_last uuid;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = 'P0001'; end if;
  select last_message_id into v_last from public.chat_rooms where id = p_room;
  update public.chat_room_members
     set left_at = now(),
         last_read_message_id = coalesce(v_last, last_read_message_id),
         updated_at = now()
   where room_id = p_room and user_id = v_me;
  if not found then raise exception 'not_a_member' using errcode = 'P0001'; end if;
end $function$;

revoke all on function public.leave_chat_room(uuid) from public, anon;
grant execute on function public.leave_chat_room(uuid) to authenticated;

-- 4) 새 메시지가 오면 나간 멤버를 재입장시켜 방이 다시 보이게 한다.
create or replace function app.chat_rejoin_on_message()
returns trigger language plpgsql security definer set search_path to '' as $function$
begin
  update public.chat_room_members
     set left_at = null, updated_at = now()
   where room_id = new.room_id and left_at is not null;
  return new;
end $function$;

drop trigger if exists trg_chat_messages_rejoin on public.chat_messages;
create trigger trg_chat_messages_rejoin
  after insert on public.chat_messages
  for each row execute function app.chat_rejoin_on_message();

-- 5) 내가 다시 채팅을 시작하면 내 left_at 해제(상대는 새 메시지 때만 재표시)
create or replace function public.start_direct_chat(p_other uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_me uuid := app.uid();
  v_key text;
  v_room uuid;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = 'P0001'; end if;
  if p_other is null or p_other = v_me then raise exception 'invalid_target' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.users where id = p_other and status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  -- 두 사용자 정렬로 결정적 canonical_key
  v_key := 'direct:' || least(v_me, p_other)::text || ':' || greatest(v_me, p_other)::text;

  select id into v_room from public.chat_rooms where canonical_key = v_key;
  if v_room is null then
    insert into public.chat_rooms(room_type, canonical_key)
      values ('direct', v_key)
      on conflict (canonical_key) do nothing
      returning id into v_room;
    if v_room is null then
      select id into v_room from public.chat_rooms where canonical_key = v_key;
    end if;
  end if;

  -- 멤버십 보강(누락분만)
  insert into public.chat_room_members(room_id, user_id)
    select v_room, t.x
    from (values (v_me), (p_other)) as t(x)
    where not exists (
      select 1 from public.chat_room_members m
      where m.room_id = v_room and m.user_id = t.x
    );

  -- 내가 나갔던 방이면 다시 참여 처리
  update public.chat_room_members
     set left_at = null, updated_at = now()
   where room_id = v_room and user_id = v_me and left_at is not null;

  return v_room;
end;
$function$;
