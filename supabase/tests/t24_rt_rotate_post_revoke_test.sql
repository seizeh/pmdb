-- refresh 회전 — 패밀리 회수(로그아웃·비번변경) 뒤에는 grace 로 부활하지 않는다
-- (20260810093000 회귀 방지).
--
-- rt_rotate 는 본문 전체 재정의로 관리돼 분기가 조용히 되돌아갈 수 있다.
-- 부활 여부는 반환값만으로 부족해 "패밀리에 살아있는 토큰 수" 로도 확인한다.
--
-- 정상 grace(동시요청 구제)까지 함께 검사한다 — 부활만 막고 구제를 죽이면
-- 회전 경합마다 로그아웃되는 회귀가 된다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(9);

create temp table rt_seed (k text primary key, id uuid not null);
insert into rt_seed select 'user', id from seed where k = 'owner';

-- ── ① 로그아웃 직후: 회전 전 토큰으로 재시도해도 부활하지 않는다 ────────────
--    로그아웃 요청 자체가 회전을 유발할 수 있어(access 만료 임박) 흔한 순서다.
insert into app.refresh_tokens (user_id, token_hash, family_id, expires_at, absolute_expires_at)
select (select id from rt_seed where k='user'), 'T24_A1', gen_random_uuid(),
       now() + interval '30 days', now() + interval '90 days';
create temp table fam_a as
  select family_id from app.refresh_tokens where token_hash = 'T24_A1';

select is(
  (select result from public.rt_rotate('T24_A1', 'T24_A2')),
  'rotated', '준비: A1 → A2 회전');

select lives_ok($$ select public.rt_revoke_family('T24_A2') $$,
  '준비: 로그아웃(최신 토큰으로 패밀리 회수)');

select is(
  (select result from public.rt_rotate('T24_A1', 'T24_A3')),
  'reuse_revoked', '로그아웃 뒤 회전 전 토큰 재사용은 거절된다');

select is(
  (select count(*) from app.refresh_tokens
    where family_id = (select family_id from fam_a) and revoked_at is null),
  0::bigint, '로그아웃 뒤 살아있는 토큰이 없다(세션 부활 없음)');

-- ── ② 정상 동시요청 구제(grace)는 그대로 살아 있다 ─────────────────────────
insert into app.refresh_tokens (user_id, token_hash, family_id, expires_at, absolute_expires_at)
select (select id from rt_seed where k='user'), 'T24_B1', gen_random_uuid(),
       now() + interval '30 days', now() + interval '90 days';

select is(
  (select result from public.rt_rotate('T24_B1', 'T24_B2')),
  'rotated', '준비: B1 → B2 회전');

select is(
  (select result from public.rt_rotate('T24_B1', 'T24_B3')),
  'grace', '회수가 없었으면 회전 직후 동시요청은 여전히 구제된다');

-- ── ③ 비밀번호 변경·정지(rt_revoke_user) 뒤에도 같은 창이 닫혀 있다 ────────
insert into app.refresh_tokens (user_id, token_hash, family_id, expires_at, absolute_expires_at)
select (select id from rt_seed where k='user'), 'T24_C1', gen_random_uuid(),
       now() + interval '30 days', now() + interval '90 days';

select is(
  (select result from public.rt_rotate('T24_C1', 'T24_C2')),
  'rotated', '준비: C1 → C2 회전');

select lives_ok($$ select public.rt_revoke_user(
    (select id from rt_seed where k='user')) $$,
  '준비: 사용자 전체 회수(비밀번호 변경·정지)');

select is(
  (select result from public.rt_rotate('T24_C1', 'T24_C3')),
  'reuse_revoked', '사용자 전체 회수 뒤에도 회전 전 토큰은 거절된다');

select * from finish();
rollback;
