-- 간이 회원 → 정식 회원 승격 (0029). signup_user 의 lite 분기가 살아 있는가.
--
-- 이 분기는 **구현돼 있었는데 도달할 수 없었다** — send-phone-code 가 계정 존재를
-- status 없이 보고 phone_taken 을 돌려주는 바람에 signup 목적 인증을 못 받았다.
-- 앞단은 엣지 함수라 여기서 못 재고, 뒷단(이 분기)만 못 박는다. 분기가 지워지면
-- 같은 번호로 정식 가입할 때 phone_taken 이 나면서 후기 연속성이 끊긴다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(7);

-- 간이 계정 — signup_lite_user 가 만드는 모양 그대로(비번은 검증 불가 sentinel).
with u as (
  insert into public.users (username, password_hash, nickname, user_type, phone,
                            phone_verified, status)
  values ('lite_promo01', '!', 'lite_promo01', 'no_pet', '01088880001',
          true, 'lite')
  returning id
) insert into seed select 'lite1', id from u;

-- signup_user 는 30분 내 signup 목적 인증을 요구한다.
insert into public.phone_verifications (phone, code, purpose, is_used, expires_at)
values ('01088880001', '123456', 'signup', true, now() + interval '5 minutes');

select is(
  (select status from public.users where id = (select id from seed where k='lite1')),
  'lite', '사전: 간이 계정 상태');

-- ── 승격 ──────────────────────────────────────────────────────────────────
select lives_ok(
  $$select public.signup_user('promoted01', '$argon2id$fake', '승격닉', 'no_pet',
                              '01088880001', false)$$,
  '같은 번호로 정식 가입이 통과한다(phone_taken 이 아니다)');

-- 새 행이 생기지 않고 **기존 행이 승격**돼야 한다 — 그래야 후기가 딸려 온다.
select is(
  (select count(*)::int from public.users where phone = '01088880001'),
  1, '행이 새로 생기지 않는다(기존 간이 행을 승격)');
select is(
  (select id from public.users where phone = '01088880001'),
  (select id from seed where k='lite1')::uuid,
  'id 가 유지된다 — 간이로 쓴 후기가 그대로 연결된다');
select is(
  (select status from public.users where id = (select id from seed where k='lite1')),
  'active', '상태가 active 로 승격된다');
select is(
  (select username from public.users where id = (select id from seed where k='lite1')),
  'promoted01', '아이디가 사용자가 고른 값으로 바뀐다(lite_ 자동값이 아니다)');

-- ── 정식 회원은 그대로 거부 ───────────────────────────────────────────────
-- 승격 분기가 status 를 안 보면 남의 계정을 가입으로 덮어쓸 수 있게 된다.
insert into public.phone_verifications (phone, code, purpose, is_used, expires_at)
values ((select phone from public.users where id = (select id from seed where k='owner')),
        '123456', 'signup', true, now() + interval '5 minutes');
select throws_like(
  $$select public.signup_user('another01', '$argon2id$fake', '다른닉', 'no_pet',
                              (select phone from public.users
                                where id = (select id from seed where k='owner')), false)$$,
  '%phone_taken%',
  '정식 회원 번호는 여전히 거부된다(승격은 lite 에만)');

select * from finish();
rollback;
