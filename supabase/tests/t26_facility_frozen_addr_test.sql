-- 동결 행 주소 변경 감지 — 사람 기억을 대체하는 장치가 실제로 울리는가.
--
-- 이 트리거의 실패 방식도 t21 과 같다: "틀린 알람" 이 아니라 **"아무 알람도 안 옴"**.
-- 재적재는 한 달에 한 번이고 어긋나는 행은 한 개라, 안 울려도 아무도 모른다.
-- 그래서 울려야 할 때(동결 행 주소 변경)와 울리면 안 될 때(일반 행·주소 무변경)를
-- 함께 못 박는다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(6);

-- 관리자 한 명 — 알람 수신자(ops_alarm_fire 가 notifications 를 만든다).
with u as (
  insert into public.users (username, password_hash, nickname, user_type, status)
  values ('t_admin26', 'x', '시드관리자', 'admin', 'active')
  returning id
) insert into seed select 'admin', id from u;

-- 시설 두 행: 동결(owner_updated_at 有) / 일반.
insert into public.facilities (category, source, ext_id, name, address, owner_updated_at)
values ('grooming', 'test', 't26-frozen', '동결샵', '옛 주소 1', now());
insert into public.facilities (category, source, ext_id, name, address)
values ('grooming', 'test', 't26-normal', '일반샵', '옛 주소 2');

-- ── 1. 동결 행의 주소가 바뀌면 울린다 ─────────────────────────────────────
update public.facilities set address = '새 주소 1' where ext_id = 't26-frozen';

select is(
  (select count(*)::int from app.ops_alarms
    where alarm_key = 'facility_frozen_addr:'
       || (select id from public.facilities where ext_id = 't26-frozen')),
  1, '동결 행 주소 변경은 알람 1건');
select is(
  (select count(*)::int from public.notifications n
    where n.user_id = (select id from seed where k = 'admin')
      and n.title = '이름 동결 시설의 주소가 바뀜'),
  1, '활성 관리자에게 알림이 간다');
select is(
  (select (a.detail->>'old_address') || '→' || (a.detail->>'new_address')
     from app.ops_alarms a
    where a.alarm_key like 'facility_frozen_addr:%' limit 1),
  '옛 주소 1→새 주소 1', 'detail 에 변경 전후 주소가 남는다 — 알람만 보고 판단할 수 있어야 한다');

-- ── 2. 쿨다운 — 같은 행을 하루 안에 또 덮어도 중복으로 울리지 않는다 ──────
update public.facilities set address = '새 주소 1-2' where ext_id = 't26-frozen';
select is(
  (select count(*)::int from app.ops_alarms where alarm_key like 'facility_frozen_addr:%'),
  1, '행별 쿨다운(1일) 안의 재변경은 접힌다');

-- ── 3. 울리면 안 될 때 ────────────────────────────────────────────────────
update public.facilities set address = '새 주소 2' where ext_id = 't26-normal';
update public.facilities set phone = '0311234567' where ext_id = 't26-frozen';
select is(
  (select count(*)::int from app.ops_alarms where alarm_key like 'facility_frozen_addr:%'),
  1, '일반 행 주소 변경·동결 행 주소 외 변경은 울리지 않는다');

-- ── 4. 알람 실패가 적재를 막지 않는다 ─────────────────────────────────────
-- ops_alarms 에 같은 트랜잭션이 못 넣게 만들 방법이 마땅치 않으니, 함수를 직접
-- 깨진 인자로 불러 예외 삼킴을 검증하는 대신 **트리거 함수의 예외 절이 UPDATE 를
-- 살리는지**를 본다: ops_alarm_fire 를 일시적으로 실패하게 바꾼다.
create or replace function app.ops_alarm_fire(
  p_key text, p_cooldown_min integer, p_title text, p_body text, p_detail jsonb)
returns integer language plpgsql security definer set search_path to '' as
$t26$ begin raise exception 't26: 강제 실패'; end $t26$;

update public.facilities set address = '새 주소 1-3' where ext_id = 't26-frozen';
select is(
  (select address from public.facilities where ext_id = 't26-frozen'),
  '새 주소 1-3', '알람이 죽어도 적재(UPDATE)는 산다 — 예외 삼킴');

select * from finish();
rollback;
