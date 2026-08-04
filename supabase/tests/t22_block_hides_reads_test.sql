-- 차단은 접촉 차단 — **읽기도 막히는가.**
--
-- 앱 화면은 예전부터 가려져 있었다(피드 뷰가 자체 WHERE 로 걸렀다). 그래서 "가려진 것이
-- 화면인지 데이터인지" 가 눈으로는 구분되지 않는다. 여기서는 **RLS 자체**를 잰다 —
-- 그러려면 postgres 가 아니라 `authenticated` 로 내려가야 한다(테이블 소유자에게는
-- RLS 가 적용되지 않아, 역할을 안 바꾸면 이 테스트는 전부 통과하며 아무것도 재지 못한다).
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(10);

-- owner 와 friend 의 글·댓글을 만들어 둔다(둘 다 동네 인증된 시드 사용자).
with p as (
  insert into public.posts (user_id, category, title, content)
  select id, 'free', 'owner 글', '내용' from seed where k='owner'
  returning id
) insert into seed select 'post_owner', id from p;

with p as (
  insert into public.posts (user_id, category, title, content)
  select id, 'free', 'friend 글', '내용' from seed where k='friend'
  returning id
) insert into seed select 'post_friend', id from p;

insert into public.comments (post_id, user_id, content)
select (select id from seed where k='post_friend'), id, 'friend 댓글'
  from seed where k='friend';

-- friend 를 차단한 사람은 **owner** 다(단방향으로 넣는다 — 대칭 여부가 이 테스트의 핵심).
insert into public.user_blocks (blocker_id, blocked_id)
select (select id from seed where k='owner'), (select id from seed where k='friend');

-- 역할을 내리면 임시 테이블 `seed` 도 못 읽는다(pg_temp 는 생성자 소유).
-- 테스트 데이터의 id 를 계속 찾아야 하므로 읽기 권한만 넘긴다.
grant select on seed to authenticated;

-- ── 차단한 쪽(owner) 시점 ──────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);

select is((select count(id)::int from public.posts where id = (select id from seed where k='post_friend')),
  0, '차단한 사람은 상대 글을 못 읽는다');
select is((select count(id)::int from public.comments where user_id = (select id from seed where k='friend')),
  0, '댓글도 못 읽는다');
select is((select count(id)::int from public.posts where id = (select id from seed where k='post_owner')),
  1, '자기 글은 그대로 보인다');

-- ── 차단당한 쪽(friend) 시점 — 대칭이어야 한다 ────────────────────────────
-- 단방향으로 차단했지만 조건은 방향 무관이다. 이게 깨지면 "차단했더니 상대는 계속
-- 내 글을 본다" 가 되어, 차단이 반쪽만 작동한다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);

select is((select count(id)::int from public.posts where id = (select id from seed where k='post_owner')),
  0, '차단당한 사람도 상대 글을 못 읽는다(방향 무관)');
select is((select count(id)::int from public.posts where id = (select id from seed where k='post_friend')),
  1, '자기 글은 그대로 보인다');

-- ── 무관한 사용자 ─────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='unverified'), 'tv', 0)::text, true);
select is((select count(id)::int from public.posts
            where id in ((select id from seed where k='post_owner'),
                         (select id from seed where k='post_friend'))),
  2, '제3자에게는 둘 다 보인다 — 차단은 당사자 사이의 일이다');

-- ── 비로그인 ──────────────────────────────────────────────────────────────
-- 익명에게는 차단 개념이 없다. blocked_ids() 가 빈 배열이 되어 조건이 통과해야 하는데,
-- 여기서 NULL 취급을 잘못하면 **모든 글이 사라진다**(익명 피드가 통째로 빈다).
select set_config('request.jwt.claims', '', true);
select is((select count(id)::int from public.posts
            where id in ((select id from seed where k='post_owner'),
                         (select id from seed where k='post_friend'))),
  2, '비로그인은 영향을 받지 않는다');

reset role;

-- ── 관리자 ────────────────────────────────────────────────────────────────
-- 신고 처리하려면 양쪽을 다 봐야 한다.
with u as (
  insert into public.users (username, password_hash, nickname, user_type, status)
  values ('t22_admin', 'x', 't22관리자', 'admin', 'active') returning id
) insert into seed select 'admin', id from u;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='admin'), 'tv', 0)::text, true);
select is((select count(id)::int from public.posts
            where id in ((select id from seed where k='post_owner'),
                         (select id from seed where k='post_friend'))),
  2, '관리자는 차단과 무관하게 전부 본다');
reset role;

-- ── 헬퍼 자체 ─────────────────────────────────────────────────────────────
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);
select is((select array_length(app.blocked_ids(), 1)), 1,
  'blocked_ids() 는 상대 1명을 돌려준다');
select set_config('request.jwt.claims', '', true);
select is((select coalesce(array_length(app.blocked_ids(), 1), 0)), 0,
  '비로그인은 빈 배열 — NULL 이 아니다(NULL 이면 비교가 통째로 NULL 이 된다)');

select * from finish();
rollback;
