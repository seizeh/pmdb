-- 차단 표시층 — v_facility_review_comment_feed 가 차단 상대의 댓글을 거른다
-- (20260807120000 회귀 방지). 피드 뷰는 본문 전체 재정의로 관리돼 필터가 조용히
-- 빠질 수 있고, replay_check 는 양쪽 다 빠지면 통과한다 — 그래서 의미를 직접 검사한다.
-- 필터는 "차단 관계인 **타인**의 댓글" 만 거른다 — 자기 댓글은 항상 보인다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(4);

-- 시드: 시설 1 + owner 의 후기 + owner·friend 각자의 댓글 1건씩.
create temp table frc_seed (k text primary key, id uuid not null);

with f as (
  insert into public.facilities (category, source, ext_id, name)
  values ('animal_hospital', 'test', 't23-f1', '테스트병원')
  returning id
)
insert into frc_seed select 'fac', id from f;

with r as (
  insert into public.facility_reviews (facility_id, user_id, rating, content)
  select (select id from frc_seed where k='fac'),
         (select id from seed where k='owner'), 5, '후기'
  returning id
)
insert into frc_seed select 'rev', id from r;

insert into public.facility_review_comments (review_id, user_id, content)
select (select id from frc_seed where k='rev'),
       (select id from seed where k='friend'), 'friend 의 댓글';
insert into public.facility_review_comments (review_id, user_id, content)
select (select id from frc_seed where k='rev'),
       (select id from seed where k='owner'), 'owner 의 댓글';

-- ① 차단 전: owner 에게 둘 다 보인다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);
select is(
  (select count(*) from public.v_facility_review_comment_feed
    where review_id = (select id from frc_seed where k='rev')),
  2::bigint, '차단 전 — 둘 다 표시');

-- owner 가 friend 를 차단.
insert into public.user_blocks (blocker_id, blocked_id)
select (select id from seed where k='owner'), (select id from seed where k='friend');

-- ② 차단한 쪽(owner): friend 의 댓글만 숨고 자기 것은 보인다.
select is(
  (select count(*) from public.v_facility_review_comment_feed
    where review_id = (select id from frc_seed where k='rev')),
  1::bigint, '차단 후 — 차단한 쪽은 상대 댓글만 숨김');

-- ③ 차단당한 쪽(friend): owner 의 댓글이 숨는다(방향 무관 — blocked_ids 축).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text,
  true);
select is(
  (select count(*) from public.v_facility_review_comment_feed
    where review_id = (select id from frc_seed where k='rev')),
  1::bigint, '차단 후 — 당한 쪽도 상대 댓글만 숨김');

-- ④ 비로그인(anon)은 영향 없다 — blocked_ids() 가 빈 배열.
select set_config('request.jwt.claims', '', true);
select is(
  (select count(*) from public.v_facility_review_comment_feed
    where review_id = (select id from frc_seed where k='rev')),
  2::bigint, '비로그인 열람 불변');

select * from finish();
rollback;
