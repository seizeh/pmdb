-- 사진 인증 게이트 순번 불변식 — 펫별 **1·4·10번째** 검증 카테고리 글에서만
-- 촬영 인증을 요구하고(총 3회), 나머지는 면제. 10번째를 넘기면 이후로는 면제.
-- 순번의 근거는 pets.verify_post_count 이며 post_pets 트리거가 올린다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(10);

-- 판정 함수 자체(앱 MyPet.needsPhotoGate 와 같은 규칙).
select is(app.needs_photo_gate(0), true,  '1번째 글 → 인증 필요');
select is(app.needs_photo_gate(1), false, '2번째 글 → 면제');
select is(app.needs_photo_gate(3), true,  '4번째 글 → 인증 필요');
select is(app.needs_photo_gate(9), true,  '10번째 글 → 인증 필요');
select is(app.needs_photo_gate(10), false, '11번째 글 → 면제');

-- owner 로 인증(RPC 는 app.uid() = JWT sub).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);

-- 첫 글 — 토큰 없이는 거부.
select throws_like(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from seed where k='pet1')],
      'https://x.test/a.jpg', 'image/jpeg', 1000, null)$$,
  '%사진 검증 정보가 올바르지 않습니다%',
  '첫 글은 촬영 인증 없이 작성 불가'
);

-- 첫 글 — 유효 토큰으로 작성(→ verify_post_count 1).
with t as (
  insert into public.photo_verifications
    (user_id, pet_id, purpose, result, ai_pass, region_matched, ai_matched,
     image_url, expires_at)
  select s.id, p.id, 'post', 'pass', true, true, true,
         'https://x.test/a.jpg', now() + interval '10 minutes'
    from seed s, seed p where s.k='owner' and p.k='pet1'
  returning id
)
select set_config('t16.tok', (select id from t)::text, true);

select lives_ok(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from seed where k='pet1')],
      'https://x.test/a.jpg', 'image/jpeg', 1000,
      current_setting('t16.tok', true)::uuid)$$,
  '첫 글은 촬영 인증으로 작성 성공'
);

select is(
  (select verify_post_count from public.pets where id = (select id from seed where k='pet1')),
  1,
  '게시 후 펫별 누적 수 +1(post_pets 트리거)'
);

-- 2·3번째 글 — 면제(토큰 없이 성공). 3번째까지 올리면 누적 3 = 다음이 4번째.
select lives_ok(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from seed where k='pet1')],
      null, null, null, null)$$,
  '2번째 글은 촬영 없이 작성 성공(면제)'
);

select public.create_post_verified(
  'walk_together', '산책 구함', '내용', now() + interval '1 day',
  array[(select id from seed where k='pet1')],
  null, null, null, null);

-- 4번째 글 — 다시 인증 요구.
select throws_like(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from seed where k='pet1')],
      'https://x.test/z.jpg', 'image/jpeg', 1000, null)$$,
  '%사진 검증 정보가 올바르지 않습니다%',
  '4번째 글에서 촬영 인증 재요구'
);

select * from finish();
rollback;
