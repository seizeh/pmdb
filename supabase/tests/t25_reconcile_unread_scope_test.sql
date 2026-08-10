-- 채팅 미읽음 보정 범위 — v_chat_rooms 와 같아야 한다 (20260810095000 회귀 방지).
--
-- 보정은 로그인마다 돈다. 범위가 뷰보다 넓으면 화면에 없는 방의 미읽음이 배지에
-- 더해지고, 사용자가 배지를 지워도 **로그인할 때마다 다시 붙는다.**
-- 함수가 본문 전체 재정의로 관리돼 필터가 조용히 빠질 수 있어 의미를 직접 검사한다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(6);

create temp table rm (k text primary key, id uuid not null);

-- owner 와 friend 의 방 하나. friend 가 메시지 2건을 보냈고 owner 는 안 읽었다.
with r as (
  insert into public.chat_rooms (room_type, canonical_key)
  values ('direct', 't25-room')
  returning id
)
insert into rm select 'room', id from r;

insert into public.chat_room_members (room_id, user_id)
select (select id from rm where k='room'), (select id from seed where k='owner');
insert into public.chat_room_members (room_id, user_id)
select (select id from rm where k='room'), (select id from seed where k='friend');

insert into public.chat_messages (room_id, sender_id, content)
select (select id from rm where k='room'), (select id from seed where k='friend'), '안녕';
insert into public.chat_messages (room_id, sender_id, content)
select (select id from rm where k='room'), (select id from seed where k='friend'), '있어?';

-- ① 평시: 두 건이 잡힌다.
select lives_ok(
  $$ select app.reconcile_unread_counts((select id from seed where k='owner')) $$,
  '준비: 보정 실행');
select is(
  (select unread_chat_count from public.users where id = (select id from seed where k='owner')),
  2, '평시에는 미읽음 2건이 잡힌다');

-- ② 차단하면 그 방은 화면에서 사라진다 — 보정도 세지 않아야 한다.
--    (세면 배지가 로그인할 때마다 되살아난다.)
insert into public.user_blocks (blocker_id, blocked_id)
select (select id from seed where k='owner'), (select id from seed where k='friend');

select lives_ok(
  $$ select app.reconcile_unread_counts((select id from seed where k='owner')) $$,
  '준비: 차단 후 보정 실행');
select is(
  (select unread_chat_count from public.users where id = (select id from seed where k='owner')),
  0, '차단 상대와의 방은 보정에서 제외된다');

-- ③ 나간 방도 마찬가지. 차단을 풀고 left_at 만 세운다.
delete from public.user_blocks
 where blocker_id = (select id from seed where k='owner');
update public.chat_room_members
   set left_at = now()
 where room_id = (select id from rm where k='room')
   and user_id = (select id from seed where k='owner');

select lives_ok(
  $$ select app.reconcile_unread_counts((select id from seed where k='owner')) $$,
  '준비: 나간 뒤 보정 실행');
select is(
  (select unread_chat_count from public.users where id = (select id from seed where k='owner')),
  0, '나간 방은 보정에서 제외된다');

select * from finish();
rollback;
