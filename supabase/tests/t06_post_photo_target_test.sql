-- 게시글 사진 인증 촬영 대상 불변식 — 미인증 펫 포함 시 사진 검증 필수는 유지하되,
-- 촬영 대상은 '연결한 펫 중 아무나'(인증 펫 촬영 허용, 2026-07-20 완화).
-- 구버전은 인증 펫 토큰을 거부했다('인증이 필요한 반려동물을 촬영해주세요') — ① 이 그 회귀 가드.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(7);

-- 추가 시드: pet1 은 인증(trust>=3), pet2 는 미인증(trust 0 기본값).
create temp table t06 (k text primary key, id uuid not null);
update public.pets set trust_score = 3
 where id = (select id from seed where k='pet1');
with p as (
  insert into public.pets (primary_guardian_id, name, species)
  select id, '시드펫2', '믹스' from seed where k='owner'
  returning id
)
insert into t06 select 'pet2', id from p;

-- owner 의 유효 사진 토큰 2장 — 둘 다 촬영 대상은 '인증된' pet1.
with t as (
  insert into public.photo_verifications
    (user_id, pet_id, purpose, result, ai_pass, region_matched, ai_matched,
     image_url, expires_at)
  select s.id, p.id, 'post', 'pass', true, true, true,
         'https://x.test/a.jpg', now() + interval '10 minutes'
    from seed s, seed p where s.k='owner' and p.k='pet1'
  returning id
)
insert into t06 select 'tok_a', id from t;
with t as (
  insert into public.photo_verifications
    (user_id, pet_id, purpose, result, ai_pass, region_matched, ai_matched,
     image_url, expires_at)
  select s.id, p.id, 'post', 'pass', true, true, true,
         'https://x.test/b.jpg', now() + interval '10 minutes'
    from seed s, seed p where s.k='owner' and p.k='pet1'
  returning id
)
insert into t06 select 'tok_b', id from t;

-- owner 로 인증(RPC 는 app.uid() = JWT sub).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);

-- ① 완화 핵심: 미인증 pet2 + 인증 pet1 연결, 촬영 대상이 인증 펫이어도 성공.
select lives_ok(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from seed where k='pet1'), (select id from t06 where k='pet2')],
      'https://x.test/a.jpg', 'image/jpeg', 1000,
      (select id from t06 where k='tok_a'))$$,
  '미인증 펫 포함 + 인증 펫 촬영 토큰 → 작성 성공(완화 회귀 가드)'
);

-- ② 토큰은 1회용으로 소모된다.
select ok(
  (select consumed_at is not null from public.photo_verifications
    where id = (select id from t06 where k='tok_a')),
  '사용한 사진 토큰 소모(consumed_at)'
);

-- ③ 동일개체 대조 통과 시 촬영된 펫의 매칭 카운트 증가.
select is(
  (select pet_match_count from public.pets
    where id = (select id from seed where k='pet1')),
  1,
  '촬영 펫 pet_match_count 증가'
);

-- ④ 촬영 대상이 연결 목록에 없으면 여전히 거부(완화의 경계).
select throws_like(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from t06 where k='pet2')],
      'https://x.test/b.jpg', 'image/jpeg', 1000,
      (select id from t06 where k='tok_b'))$$,
  '%촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다%',
  '연결하지 않은 펫 촬영 토큰 거부'
);

-- ⑤ 미인증 펫 포함인데 토큰이 없으면 거부(검증 필수 유지).
select throws_like(
  $$select public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from t06 where k='pet2')],
      'https://x.test/c.jpg', 'image/jpeg', 1000, null)$$,
  '%사진 검증 정보가 올바르지 않습니다%',
  '미인증 펫 포함 + 토큰 없음 거부'
);

-- ⑥ 전부 인증 펫이면 사진 검증 생략.
select lives_ok(
  $$select set_config('t06.p6', public.create_post_verified(
      'walk_together', '산책 구함', '내용', now() + interval '1 day',
      array[(select id from seed where k='pet1')],
      null, null, null, null)::text, true)$$,
  '전부 인증 펫 → 토큰 없이 작성 성공'
);

-- ⑦ 검증 생략 경로도 게시글은 검증됨으로 표시.
select is(
  (select is_pet_verified from public.posts
    where id = current_setting('t06.p6', true)::uuid),
  true,
  '신뢰 경로 게시글 is_pet_verified'
);

select * from finish();
rollback;
