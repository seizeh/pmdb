-- 채팅 메시지 삭제 불변식 — 본인 것만 삭제 가능(정의자 RPC 검증),
-- 삭제 시 상대 미읽음 보정·방 미리보기 갱신까지 함께 처리된다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(5);

-- 방 + 멤버 + 메시지 시드: owner 가 m1, friend 가 m2(최신) 전송.
create temp table chat_seed (k text primary key, id uuid not null);
with r as (
  insert into public.chat_rooms (room_type, canonical_key)
  values ('direct', 'direct:test-room') returning id
)
insert into chat_seed select 'room', id from r;
insert into public.chat_room_members (room_id, user_id)
select (select id from chat_seed where k='room'), id
  from seed where k in ('owner', 'friend');
with m as (
  insert into public.chat_messages (room_id, sender_id, content)
  select (select id from chat_seed where k='room'),
         (select id from seed where k='owner'), 'hello' returning id
)
insert into chat_seed select 'm1', id from m;
with m as (
  insert into public.chat_messages (room_id, sender_id, content)
  select (select id from chat_seed where k='room'),
         (select id from seed where k='friend'), 'world' returning id
)
insert into chat_seed select 'm2', id from m;

-- friend 로 인증(정의자 RPC 는 app.uid() = JWT sub 를 본다).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text,
  true);

-- ① 타인(owner)의 m1 은 삭제 불가.
select throws_like(
  $$select public.delete_my_chat_message((select id from chat_seed where k='m1'))$$,
  '%내가 보낸 메시지만%',
  '타인 메시지 삭제 거부'
);

-- ② 내 메시지(m2, 방의 최신) 삭제는 성공.
select lives_ok(
  $$select public.delete_my_chat_message((select id from chat_seed where k='m2'))$$,
  '본인 메시지 삭제 성공'
);
select is(
  (select is_deleted from public.chat_messages
    where id = (select id from chat_seed where k='m2')),
  true,
  '소프트 삭제 플래그 세팅'
);

-- ③ 아직 안 읽은 상대(owner)의 미읽음 카운터 보정(m2 수신분 -1 → 0).
select is(
  (select unread_chat_count from public.users
    where id = (select id from seed where k='owner')),
  0,
  '미읽음 카운터 보정'
);

-- ④ 방 미리보기는 다음 최신 비삭제 메시지(m1)로 갱신.
select is(
  (select last_message_preview from public.chat_rooms
    where id = (select id from chat_seed where k='room')),
  'hello',
  '방 미리보기가 이전 메시지로 갱신'
);

select * from finish();
rollback;
