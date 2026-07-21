-- 게시글 작성 불변식 — 업체 모드 글은 항상 news 로 강제(사업장 지역 스탬프,
-- 동네 인증 면제), 개인 모드는 news 금지 + 동네 인증 게이트.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(5);

-- ① 업체 모드: 개인 동네 인증이 없어도 작성 가능(면제).
select lives_ok(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'free', '소식 제목', '소식 내용' from seed where k='bizowner'$$,
  '업체 모드 글 작성 — 개인 동네 인증 없이 성공'
);

-- ② 카테고리는 무엇을 보내든 news 로 강제된다.
select is(
  (select p.category from public.posts p
     join seed s on s.id = p.user_id and s.k='bizowner' limit 1),
  'news',
  '업체 모드 글은 news 로 강제'
);

-- ③ 지역은 개인 인증 동이 아니라 사업장 지역코드로 스탬프.
select is(
  (select p.region_code from public.posts p
     join seed s on s.id = p.user_id and s.k='bizowner' limit 1),
  '4100000000',
  '업체 소식 지역 = business_region_code'
);

-- ④ 개인 모드의 news 는 거부(소식은 업체 전용 분류).
select throws_like(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'news', 't', 'c' from seed where k='owner'$$,
  '%업체 계정 전용%',
  '개인 모드 news 거부'
);

-- ⑤ 동네 인증이 없는 개인은 카테고리 무관 작성 불가.
select throws_like(
  $$insert into public.posts (user_id, category, title, content)
    select id, 'free', 't', 'c' from seed where k='unverified'$$,
  '%동네 인증%',
  '미인증 개인 작성 차단(지역 게이트)'
);

select * from finish();
rollback;
