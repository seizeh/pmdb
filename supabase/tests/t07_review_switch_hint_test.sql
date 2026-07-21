-- 후기 딥링크 '업체 모드로 전환할까요?' 판정 불변식 — review_owner_switch_hint 는
-- 승인 업주 && 후기 시설이 자기 업체 매칭 시설(형제 포함) && 현재 개인 모드일 때만 true.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(4);

-- 추가 시드: bizowner 의 매칭 시설 + friend 가 남긴 후기.
create temp table t07 (k text primary key, id uuid not null);
with f as (
  insert into public.facilities (category, source, ext_id, name)
  values ('animal_hospital', 'test', 't07-f1', '전환테스트병원')
  returning id
)
insert into t07 select 'fac', id from f;

update public.business_profiles
   set matched_facility_id = (select id from t07 where k='fac')
 where user_id = (select id from seed where k='bizowner');

with r as (
  insert into public.facility_reviews (facility_id, user_id, rating, content)
  select (select id from t07 where k='fac'), id, 5, '친절해요'
    from seed where k='friend'
  returning id
)
insert into t07 select 'rev', id from r;

-- ① 승인 업주가 개인 모드로 자기 시설 후기에 진입 → 전환 제안.
update public.users set active_mode = 'personal'
 where id = (select id from seed where k='bizowner');
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text,
  true);
select is(
  public.review_owner_switch_hint((select id from t07 where k='rev')),
  true,
  '승인 업주 + 개인 모드 → 제안 true'
);

-- ② 이미 업체 모드면 제안하지 않는다.
update public.users set active_mode = 'business'
 where id = (select id from seed where k='bizowner');
select is(
  public.review_owner_switch_hint((select id from t07 where k='rev')),
  false,
  '이미 업체 모드 → false'
);

-- ③ 업주가 아닌 사용자에게는 제안하지 않는다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);
select is(
  public.review_owner_switch_hint((select id from t07 where k='rev')),
  false,
  '비업주 → false'
);

-- ④ 승인 전(pending) 업체는 개인 모드여도 제안하지 않는다.
update public.users set active_mode = 'personal'
 where id = (select id from seed where k='bizowner');
update public.business_profiles set status = 'pending'
 where user_id = (select id from seed where k='bizowner');
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text,
  true);
select is(
  public.review_owner_switch_hint((select id from t07 where k='rev')),
  false,
  '미승인 업체 → false'
);

select * from finish();
rollback;
