-- 영업자 공통 차단선(0028 §2) — 승인 업체 계정은 활성 모드 무관 분양·입양 게시 불가.
-- 업체 모드는 기존 불변식이 news 로 강제하므로, 여기서는 **개인 모드로 전환한
-- 영업자**의 우회 경로(신규 작성·카테고리 수정)를 검증한다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(5);

-- bizowner 를 개인 모드로 전환 + 동네 인증 부여(지역 게이트가 아니라
-- 영업자 차단이 걸리는지 보기 위해 다른 게이트는 통과시킨다).
update public.users
   set active_mode = 'personal', region_code = '1111010100',
       address = '서울 종로구 청운동', is_location_verified = true,
       last_verified_at = now()
 where id = (select id from seed where k = 'bizowner');

-- ① 개인 모드 영업자의 입양(adoption) 글 → 차단.
select throws_like(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'adoption', '입양', 'c' from seed where k='bizowner'$$,
  '%영업자 계정은 분양·입양%',
  '개인 모드 영업자 adoption 차단'
);

-- ② 분양(give_away)도 동일 차단.
select throws_like(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'give_away', '분양', 'c' from seed where k='bizowner'$$,
  '%영업자 계정은 분양·입양%',
  '개인 모드 영업자 give_away 차단'
);

-- ③ 매칭 무관 카테고리(free)는 개인 모드 영업자도 작성 가능.
select lives_ok(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'free', '잡담', 'c' from seed where k='bizowner'$$,
  '영업자라도 분양·입양 외 카테고리는 허용'
);

-- ④ 우회 봉쇄: 허용 카테고리로 넣은 글을 adoption 으로 수정 → 차단.
select throws_like(
  $$update public.posts set category = 'adoption'
    where user_id = (select id from seed where k='bizowner')$$,
  '%영업자 계정은 분양·입양%',
  '카테고리 수정 우회 차단(UPDATE OF category)'
);

-- ⑤ 일반 개인(owner)의 adoption 은 영향 없음.
select lives_ok(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'adoption', '입양 희망', 'c' from seed where k='owner'$$,
  '일반 개인 adoption 작성은 그대로 허용'
);

select * from finish();
rollback;
