-- 간이 후기 계정 전화번호 파기 (20260804090000).
--
-- 「간이 후기 이용조건」 §3 과 개인정보 처리방침 §3 이 약속한 파기가 실제로 도는지.
-- 파기는 안 해도 아무 일이 일어나지 않는 종류라(기능 정상·화면 멀쩡) 자동 검증이
-- 없으면 다시 조용히 멈춘다 — 실제로 이 약속은 구현 없이 일주일 넘게 게시돼 있었다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(6);

-- 간이 계정 3종 — 후기 있음 / 후기 없음(어제) / 후기 없음(방금).
with u as (
  insert into public.users (username, password_hash, nickname, user_type, phone,
                            phone_verified, status, created_at)
  values ('t_lite_kept', '!', 'lite_kept', 'no_pet', '01099990001',
          true, 'lite', now() - interval '2 days')
  returning id
) insert into seed select 'lite_kept', id from u;

with u as (
  insert into public.users (username, password_hash, nickname, user_type, phone,
                            phone_verified, status, created_at)
  values ('t_lite_gone', '!', 'lite_gone', 'no_pet', '01099990002',
          true, 'lite', now() - interval '2 days')
  returning id
) insert into seed select 'lite_gone', id from u;

-- 방금 인증만 받고 아직 후기를 쓰는 중 — 유예 안에 있으므로 건드리면 안 된다.
with u as (
  insert into public.users (username, password_hash, nickname, user_type, phone,
                            phone_verified, status, created_at)
  values ('t_lite_fresh', '!', 'lite_fresh', 'no_pet', '01099990003',
          true, 'lite', now())
  returning id
) insert into seed select 'lite_fresh', id from u;

-- 시설 + kept 의 후기 1건.
with f as (
  insert into public.facilities (category, source, ext_id, name)
  values ('pet_cafe', 'test', 't19-fac', '시드시설')
  returning id
) insert into seed select 'fac1', id from f;

insert into public.facility_reviews (facility_id, user_id, rating, content)
select (select id from seed where k='fac1'), (select id from seed where k='lite_kept'),
       5, '좋아요';

-- 정식 회원(owner)은 후기가 없어도 대상이 아니다 — status 가 'lite' 가 아니므로.
select is(
  (select phone is not null from public.users where id = (select id from seed where k='owner')),
  true, '사전: 정식 회원은 전화번호 보유');

select app.cleanup_retention();

-- ① 후기가 남아 있으면 보존 — 작성자 식별·정식 전환 연결에 계속 쓰인다.
select is(
  (select phone from public.users where id = (select id from seed where k='lite_kept')),
  '01099990001', '후기가 있는 간이 계정은 전화번호를 보존한다');

-- ② 후기가 하나도 없으면 파기 — 이용조건 §3 이 약속한 바로 그 동작.
select is(
  (select phone from public.users where id = (select id from seed where k='lite_gone')),
  null, '후기가 없는 간이 계정은 전화번호를 파기한다');
select is(
  (select phone_verified from public.users where id = (select id from seed where k='lite_gone')),
  false, '파기 시 인증 플래그도 함께 내린다(번호 없이 인증됨 상태로 남지 않게)');

-- ③ 유예 안(방금 생성)은 건드리지 않는다 — 후기를 쓰는 중일 수 있다.
select is(
  (select phone from public.users where id = (select id from seed where k='lite_fresh')),
  '01099990003', '생성 직후 간이 계정은 유예 기간이라 보존한다');

-- ④ 정식 회원은 후기 유무와 무관하게 대상이 아니다.
select is(
  (select phone is not null from public.users where id = (select id from seed where k='owner')),
  true, '정식 회원 전화번호는 이 배치가 건드리지 않는다');

select * from finish();
rollback;
