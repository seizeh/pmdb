-- 팔로우 얼굴 분리 불변식 — 같은 사용자의 개인/업체 얼굴은 독립적으로 팔로우되고,
-- 목록 뷰는 얼굴에 맞는 이름(상호)과 모드별 팔로워만 보여준다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(7);

-- owner 가 bizowner 의 두 얼굴을 각각 팔로우.
select lives_ok(
  $$insert into public.pawings (follower_id, following_id, context)
    select (select id from seed where k='owner'),
           (select id from seed where k='bizowner'), 'personal'$$,
  '개인 얼굴 팔로우'
);
select lives_ok(
  $$insert into public.pawings (follower_id, following_id, context)
    select (select id from seed where k='owner'),
           (select id from seed where k='bizowner'), 'business'$$,
  '업체 얼굴 팔로우 — 개인 팔로우와 공존'
);
select throws_like(
  $$insert into public.pawings (follower_id, following_id, context)
    select (select id from seed where k='owner'),
           (select id from seed where k='bizowner'), 'personal'$$,
  '%pawings_uq%',
  '같은 얼굴 중복 팔로우는 유니크 위반'
);

-- owner 시점(v_pawing): 두 행이 각자 얼굴로 보인다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);
select is(
  (select count(*) from public.v_pawing
    where user_id = (select id from seed where k='bizowner')),
  2::bigint,
  'v_pawing — 개인·업체 팔로우 2행'
);
select is(
  (select nickname from public.v_pawing
    where user_id = (select id from seed where k='bizowner') and is_business),
  '테스트업체',
  'v_pawing 업체 행은 상호로 표시(닉네임 비노출)'
);

-- bizowner 시점(v_pawmate): 현재 계정 모드의 얼굴 팔로워만.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text,
  true);
select is(
  (select count(*) from public.v_pawmate),
  1::bigint,
  'v_pawmate(업체 모드) — 업체 얼굴 팔로워 1명'
);
update public.users set active_mode = 'personal'
 where id = (select id from seed where k='bizowner');
select is(
  (select count(*) from public.v_pawmate),
  1::bigint,
  'v_pawmate(개인 모드 전환) — 개인 얼굴 팔로워 1명'
);

select * from finish();
rollback;
