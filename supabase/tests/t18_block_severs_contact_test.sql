-- 차단이 표시뿐 아니라 **접촉**을 끊는가 (20260803190000).
--
-- 차단 이전 구현은 내 화면에서 상대를 가리는 것까지만 했고, 상대가 나에게 도달하는
-- 경로(팔로우 → 새글 푸시, 하트·댓글 → 알림)는 열려 있었다. 그 셋을 각각 못 박는다.
-- 차단은 개발 중에 거의 실행되지 않는 경로라 자동 검증이 없으면 다시 새기 쉽다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(9);

-- friend 가 owner 를 팔로우하고, owner 의 글이 하나 있다.
insert into public.pawings (follower_id, following_id, context)
select (select id from seed where k='friend'), (select id from seed where k='owner'), 'personal';

with p as (
  insert into public.posts (user_id, category, title, content, region_code, visibility_status)
  select id, 'free', '시드글', '내용', '1111010100', 'visible'
    from seed where k='owner'
  returning id
)
insert into seed select 'post1', id from p;

-- ── 차단 전: 접촉이 성립한다(대조군) ──────────────────────────────────────
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);

select lives_ok(
  $$insert into public.post_hearts (post_id, user_id)
    values ((select id from seed where k='post1'), (select id from seed where k='friend'))$$,
  '차단 전: 하트를 누를 수 있다');

select is(
  (select count(*)::int from public.pawings
    where follower_id = (select id from seed where k='friend')
      and following_id = (select id from seed where k='owner')),
  1, '차단 전: 팔로우 관계가 있다');

-- 알림 그물 대조군 — 차단이 없으면 알림 행이 만들어진다.
insert into public.notifications (user_id, actor_user_id, notification_type, title)
select (select id from seed where k='owner'), (select id from seed where k='friend'),
       'post_heart', '대조군';
select is(
  (select count(*)::int from public.notifications
    where user_id = (select id from seed where k='owner') and title = '대조군'),
  1, '차단 전: 알림 행이 생성된다');

-- ── 차단 ──────────────────────────────────────────────────────────────────
-- owner 가 friend 를 차단한다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);
select lives_ok(
  $$select public.block_user((select id from seed where k='friend'), '테스트')$$,
  'block_user 실행');

-- ── 1) 팔로우가 끊긴다 ────────────────────────────────────────────────────
-- 이게 없으면 owner 가 글을 올릴 때마다 크론이 friend 에게 새글 푸시를 보낸다.
select is(
  (select count(*)::int from public.pawings
    where (follower_id = (select id from seed where k='friend')
           and following_id = (select id from seed where k='owner'))
       or (follower_id = (select id from seed where k='owner')
           and following_id = (select id from seed where k='friend'))),
  0, '차단 후: 팔로우가 양방향으로 끊긴다(새 글 푸시 경로 제거)');

-- ── 2) 알림 그물 — 차단 쌍 사이 알림은 행 자체가 안 생긴다 ────────────────
-- 조용히 건너뛴다(예외 아님). 예외를 던지면 알림을 만들려던 원래 작업이 통째로
-- 실패하는데, 알림은 부수 효과라 본 작업을 죽이면 안 된다.
select lives_ok(
  $$insert into public.notifications (user_id, actor_user_id, notification_type, title)
    select (select id from seed where k='owner'), (select id from seed where k='friend'),
           'post_heart', '차단후'$$,
  '차단 후: 알림 INSERT 는 오류 없이 통과한다(조용히 버려진다)');
select is(
  (select count(*)::int from public.notifications
    where user_id = (select id from seed where k='owner') and title = '차단후'),
  0, '차단 후: 그 알림 행은 만들어지지 않았다(푸시·배지도 함께 멈춤)');

-- 반대 방향도 막혀야 한다 — 차단은 한쪽이 걸어도 양쪽 관계가 끊긴다.
insert into public.notifications (user_id, actor_user_id, notification_type, title)
select (select id from seed where k='friend'), (select id from seed where k='owner'),
       'post_heart', '역방향';
select is(
  (select count(*)::int from public.notifications
    where user_id = (select id from seed where k='friend') and title = '역방향'),
  0, '차단 후: 반대 방향 알림도 만들어지지 않는다');

-- ── 3) 접촉 원천 거부 — 하트·댓글 INSERT 자체가 막힌다 ────────────────────
-- 알림만 막으면 하트 수는 올라가고 댓글 행은 저장되는데 아무도 모르는 상태가 된다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select throws_like(
  $$insert into public.comments (post_id, user_id, content)
    values ((select id from seed where k='post1'), (select id from seed where k='friend'), '댓글')$$,
  '%차단%',
  '차단 후: 차단 상대의 글에 댓글을 쓸 수 없다');

select * from finish();
rollback;
