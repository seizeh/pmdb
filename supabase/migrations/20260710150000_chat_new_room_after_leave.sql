-- 나간 뒤 다시 대화를 시작하면 새 채팅방 생성 (0033/0034 후속).
--
-- 기존: canonical_key('direct:a:b') 유니크 때문에 사용자 쌍당 방이 하나뿐이라,
-- 한쪽이 나간(left_at, 전송 잠금) 방을 start_direct_chat 이 그대로 재사용했다
-- → 나간 사람이 다시 대화를 시작해도 잠긴 옛 방이 열릴 뿐 새 방이 생기지 않는 버그.
--
-- 수정: start_direct_chat 이 기존 방에 나간 멤버가 있으면 그 방을 "은퇴"시키고
-- (canonical_key 를 'direct:a:b:closed:<room_id>' 로 재부여해 키를 비움) 새 방을
-- 만든다. 옛 방은 그대로 잠긴 채(전송 차단 트리거 유지) 남아 있는 멤버의 목록에
-- 이력으로 남고, 나갔던 멤버 목록에는 보이지 않는다(left_at 필터).
-- 은퇴 키('direct:a:b:closed:<room_id>' = 124자)가 들어가도록 키 컬럼 확장.
alter table public.chat_rooms alter column canonical_key type varchar(160);

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
  v_left_exists boolean;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = 'P0001'; end if;
  if p_other is null or p_other = v_me then raise exception 'invalid_target' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.users where id = p_other and status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  -- 두 사용자 정렬로 결정적 canonical_key
  v_key := 'direct:' || least(v_me, p_other)::text || ':' || greatest(v_me, p_other)::text;

  -- 활성 키의 방을 잠그고 조회(동시 시작 경쟁 대비)
  select id into v_room from public.chat_rooms
   where canonical_key = v_key
   for update;

  if v_room is not null then
    -- 나간 멤버가 있는 방은 재사용하지 않는다 → 키를 비우고 새 방으로.
    select exists (
      select 1 from public.chat_room_members m
      where m.room_id = v_room and m.left_at is not null
    ) into v_left_exists;
    if v_left_exists then
      update public.chat_rooms
         set canonical_key = v_key || ':closed:' || v_room::text
       where id = v_room;
      v_room := null;
    end if;
  end if;

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

  return v_room;
end;
$function$;
