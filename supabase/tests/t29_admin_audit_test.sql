-- 관리자 행위 감사 — 상태를 바꾸는 admin RPC 는 원장(admin_logs)에 남는다.
--
-- v9.2 가 "감사 미기록 admin RPC 5종" 으로 명시했던 결함의 회귀 가드(20260921
-- admin_rpc_audit_logs). 특히 QR 회수는 revoked_at 만 찍혀 행위자가 시스템
-- 어디에도 없었다. 방침 둘을 함께 고정한다:
--   ① 상태가 실제로 바뀐 경우에만 기록(재사용 반환·중복 재진입은 무기록 — 노이즈 방지)
--   ② 원장에 토큰 원문을 싣지 않는다(token_prefix 8자만 — 원장이 두 번째 capability
--      저장소가 되면 안 된다)
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(13);

-- 감사자(관리자) — 시드에 admin 이 없다
with u as (
  insert into public.users (username, password_hash, nickname, user_type, status)
  values ('t29_admin', 'x', '감사관리자', 'admin', 'active')
  returning id
) insert into seed select 'admin', id from u;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='admin'), 'tv', 0)::text,
  true);

-- 픽스처: 시설 · bizowner 의 sales 허가 · admin_inquiry 방
insert into public.facilities (category, source, ext_id, name)
values ('animal_hospital', 't29', 't29-ext', '감사시설');
insert into app.business_licenses (user_id, license_type, license_no, document_path, status)
select id, 'sales', 't29-L-1', 'x', 'approved' from seed where k = 'bizowner';
with r as (
  insert into public.chat_rooms (room_type, canonical_key)
  values ('admin_inquiry', 't29-room') returning id
) insert into seed select 'room', id from r;

-- ── 1. 시설 폐업 판정 ──────────────────────────────────────────────────────
select lives_ok(
  $$ select public.admin_mark_facility_closed(f.id, true) from public.facilities f where f.ext_id = 't29-ext' $$,
  '폐업 판정이 실행된다');
select is(
  (select count(*)::int from public.admin_logs
    where action_type = 'facility_mark_closed'
      and admin_id = (select id from seed where k='admin')),
  1, '폐업 판정이 원장에 남는다 — 누가·어느 시설을');

-- ── 2. QR 발급 — 신규만 기록, 재사용은 무기록 ─────────────────────────────
create temp table t29_tok (token varchar);
insert into t29_tok
select token from public.admin_create_facility_share_link(
  (select f.id from public.facilities f where f.ext_id = 't29-ext'));
select is((select length(token) from t29_tok), 32, '시설 QR 이 발급된다');
select is(
  (select count(*)::int from public.admin_logs where action_type = 'share_link_create'),
  1, '신규 발급이 원장에 남는다');
select is(
  (select (detail->>'token_prefix') = left((select token from t29_tok), 8)
      and length(detail->>'token_prefix') = 8
     from public.admin_logs where action_type = 'share_link_create' limit 1),
  true, '원장에는 토큰 원문이 아니라 접두 8자만 남는다');

select public.admin_create_facility_share_link(
  (select f.id from public.facilities f where f.ext_id = 't29-ext'));
select is(
  (select count(*)::int from public.admin_logs where action_type = 'share_link_create'),
  1, '유효 링크 재사용 반환은 기록하지 않는다 — 상태 변경이 없다');

-- 스타터 QR (bizowner: 승인 업체 + sales 허가)
select lives_ok(
  $$ select public.admin_create_starter_share_link((select id from seed where k='bizowner')) $$,
  '스타터 QR 이 발급된다');
select is(
  (select count(*)::int from public.admin_logs where action_type = 'share_link_create'),
  2, '스타터 발급도 원장에 남는다');

-- ── 3. QR 회수 — 행위자가 남는다 ──────────────────────────────────────────
select is(
  (select public.admin_revoke_share_link((select token from t29_tok))),
  true, '회수가 실행된다');
select is(
  (select l.revoked_by from app.share_links l where l.token = (select token from t29_tok)),
  (select id from seed where k='admin'),
  '행에 회수자(revoked_by)가 남는다 — 종전에는 revoked_at 뿐이었다');
select is(
  (select count(*)::int from public.admin_logs where action_type = 'share_link_revoke'),
  1, '회수가 원장에 남는다');

-- ── 4. 문의 개입 — 신규 참여만 기록 ───────────────────────────────────────
select lives_ok(
  $$ select public.admin_join_inquiry((select id from seed where k='room')) $$,
  '문의 방 참여가 실행된다');
select public.admin_join_inquiry((select id from seed where k='room'));
select is(
  (select count(*)::int from public.admin_logs where action_type = 'inquiry_join'),
  1, '신규 참여만 원장에 남는다 — 중복 재진입(on conflict)은 무기록');

select * from finish();
rollback;
