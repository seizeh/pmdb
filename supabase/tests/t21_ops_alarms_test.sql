-- 운영 알람 — 조용히 죽지 않는가.
--
-- 이 장치의 실패 방식은 "틀린 알람" 이 아니라 **"아무 알람도 안 옴"** 이다. 그리고
-- 그건 평상시(=아무 일도 없을 때)의 정상 동작과 겉모습이 같다. 그래서 여기서
-- 못 박는 건 "울려야 할 때 울리는가" 와 "설정이 없어도 살아 있는가" 두 가지다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(12);

-- 관리자 한 명 — 알람 수신자. 시드에는 admin 이 없다.
with u as (
  insert into public.users (username, password_hash, nickname, user_type, status)
  values ('t_admin', 'x', '시드관리자', 'admin', 'active')
  returning id
) insert into seed select 'admin', id from u;

-- ── 1. 레이트리밋 발동 기록 ────────────────────────────────────────────────
select is(
  (select public.rate_limit_hit('t21a:x', 3, 60)), true, '한도 이하는 통과한다');
select is(
  (select count(*)::int from app.rate_limit_trips where family = 't21a'),
  0, '통과한 요청은 기록하지 않는다 — 평상시에 조용해야 급증이 보인다');

select public.rate_limit_hit('t21b:ip:1.2.3.4', 1, 60);  -- 1회차: 통과
select public.rate_limit_hit('t21b:ip:1.2.3.4', 1, 60);  -- 2회차: 차단
select public.rate_limit_hit('t21b:ip:5.6.7.8', 1, 60);  -- 다른 IP, 같은 계열
select public.rate_limit_hit('t21b:ip:5.6.7.8', 1, 60);  -- 차단

select is(
  (select sum(trips)::int from app.rate_limit_trips where family = 't21b'),
  2, '차단된 횟수만 세고, 같은 계열은 한 줄로 접힌다');
select is(
  (select count(distinct family)::int from app.rate_limit_trips where family like 't21b%'),
  1, 'family 는 첫 토큰만 — IP·uid 는 버린다(보관할 이유 없는 식별자)');

-- ── 2. 설정이 없어도 살아 있다 ─────────────────────────────────────────────
-- 설정 INSERT 는 데이터라 pg_dump --schema-only 에 안 담긴다. 스냅샷으로 세운
-- DB 에서는 이 테이블이 비어 있고, 예전 같으면 스윕이 조용히 0을 냈다.
delete from app.ops_alarm_config;
insert into app.client_errors (where_key, message)
select 't21.boom', 'x' from generate_series(1, 25);

select cmp_ok(app.ops_alarm_sweep(), '>=', 1,
  '설정 행이 없어도 기본값으로 되살아나 울린다');
select is(
  (select count(*)::int from app.ops_alarm_config), 1,
  '되살릴 때 설정 행을 남긴다(다음 회차부터는 조정 가능)');

-- ── 3. 무엇이 남는가 ───────────────────────────────────────────────────────
select is(
  (select count(*)::int from app.ops_alarms where alarm_key = 'client_error:t21.boom'),
  1, '알람 이력이 남는다 — 푸시를 못 받아도 되짚을 수 있어야 한다');
select is(
  (select count(*)::int from public.notifications n
    where n.user_id = (select id from seed where k = 'admin')
      and n.notification_type = 'system_notice'),
  1, '관리자에게 system_notice 로 간다(기존 푸시 파이프라인을 탄다)');

-- ── 4. 쿨다운 ──────────────────────────────────────────────────────────────
-- 급증은 몇 분간 이어진다. 5분마다 같은 알람이 오면 사람은 알림을 꺼 버리고,
-- 그럼 관측 장치가 없는 것과 같아진다.
select is(app.ops_alarm_sweep(), 0, '쿨다운 안에서는 같은 알람이 다시 울리지 않는다');

update app.ops_alarms set fired_at = now() - interval '10 days';
select cmp_ok(app.ops_alarm_sweep(), '>=', 1, '쿨다운이 지나면 다시 울린다');

-- ── 5. 끄면 꺼진다 ─────────────────────────────────────────────────────────
update app.ops_alarm_config set enabled = false;
select is(app.ops_alarm_sweep(), 0, 'enabled=false 면 아무것도 울리지 않는다');

-- ── 6. 파기 적체는 1건이어도 본다 ──────────────────────────────────────────
-- 급증이 아니라 법정 의무 미이행이라 임계가 1이다.
update app.ops_alarm_config set enabled = true;
delete from app.ops_alarms;
delete from app.client_errors where where_key = 't21.boom';
insert into app.business_doc_purge_queue (path, reason, purge_after)
values ('t21/doc.pdf', 't21', now() - interval '3 days');

-- 스윕은 **별도 문장**으로 돌린다. 한 문장 안에서 조인해 세면 스캔이 같은 스냅샷을
-- 쓰기 때문에 함수가 방금 넣은 행이 안 보인다(0을 보고 "안 울렸다" 로 오판한다).
select app.ops_alarm_sweep();
select is(
  (select count(*)::int from app.ops_alarms where alarm_key = 'purge_overdue'),
  1, '파기 지연은 1건이어도 울린다');

select * from finish();
rollback;
