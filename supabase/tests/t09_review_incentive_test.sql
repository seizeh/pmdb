-- 대가성 후기 표시(0028 §6) — has_incentive 저장·노출 + 구버전 앱(5인자 호출) 호환.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(4);

-- 추가 시드: 후기 대상 시설.
create temp table t09 (k text primary key, id uuid not null);
with f as (
  insert into public.facilities (category, source, ext_id, name)
  values ('grooming', 'test', 't09-f1', '대가성테스트미용실')
  returning id
)
insert into t09 select 'fac', id from f;

-- ① owner 가 혜택 체크로 작성 → has_incentive = true 저장.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);
select lives_ok(
  $$select public.add_facility_review(
      (select id from t09 where k='fac'), 5::smallint, '혜택 받고 씀',
      '{}', '{}', true)$$,
  '혜택 체크 후기 작성 성공'
);

-- ② 구버전 앱 호환: p_has_incentive 없이(5인자) 호출 → 기본 false.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text,
  true);
select lives_ok(
  $$select public.add_facility_review(
      p_facility => (select id from t09 where k='fac'),
      p_rating => 4::smallint, p_body => '그냥 씀',
      p_paths => '{}', p_urls => '{}')$$,
  '구버전 5인자 호출도 동작(default false)'
);

-- ③ 목록 RPC 가 has_incentive 를 그대로 노출한다.
select is(
  (select r.has_incentive from public.facility_reviews_of((select id from t09 where k='fac'), 10, 0) r
    where r.content = '혜택 받고 씀'),
  true,
  'reviews_of: 혜택 후기 has_incentive=true'
);
select is(
  (select r.has_incentive from public.facility_reviews_of((select id from t09 where k='fac'), 10, 0) r
    where r.content = '그냥 씀'),
  false,
  'reviews_of: 일반 후기 has_incentive=false'
);

select * from finish();
rollback;
