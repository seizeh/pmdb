-- 1:1 채팅방 find-or-create. 상대방 멤버십 INSERT 는 RLS(user_id=app.uid())로 막히므로
-- SECURITY DEFINER 로 처리하고 authenticated 에게만 실행 허용.
create or replace function public.start_direct_chat(p_other uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
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

  return v_room;
end;
$$;

revoke all on function public.start_direct_chat(uuid) from public;
revoke all on function public.start_direct_chat(uuid) from anon;
grant execute on function public.start_direct_chat(uuid) to authenticated;

-- 내가 팔로우하는 사람들 (Pawing)
create or replace view public.v_pawing
with (security_invoker = true) as
select pr.id as user_id, pr.nickname, pr.user_type, p.created_at
from public.pawings p
join public.public_profiles pr on pr.id = p.following_id
where p.follower_id = app.uid();

grant select on public.v_pawing to anon, authenticated;

-- 나를 팔로우하는 사람들 (Pawmate) + 내가 맞팔 중인지
create or replace view public.v_pawmate
with (security_invoker = true) as
select
  pr.id as user_id, pr.nickname, pr.user_type, p.created_at,
  exists(
    select 1 from public.pawings me
    where me.follower_id = app.uid() and me.following_id = p.follower_id
  ) as i_follow_back
from public.pawings p
join public.public_profiles pr on pr.id = p.follower_id
where p.following_id = app.uid();

grant select on public.v_pawmate to anon, authenticated;
