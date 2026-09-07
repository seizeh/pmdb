-- 시설 데이터 운영 장치 두 가지 — 0033 §8 "남은 것" 의 사람 의존을 장치로 바꾼다.
--
-- ① 월 1회 재적재 리마인더 (cron)
--
--    적재 파이프라인에는 cron 이 없다 — 함수가 CSV 를 직접 받지 않는 구조라(0033
--    §4.2) 사람이 파일을 받아 스크립트를 돌려야 한다. 그런데 이번 사고의 본질이
--    "잊혀서 6주 동결" 이었다. 잊지 않게 하는 장치까지가 파이프라인이다.
--    매월 1일 09:00 KST 에 ops_alarm_fire → 관리자 전원 알림(→ 푸시).
--
-- ② 이름 동결(owner_updated_at) 행의 주소 변경 감지 (trigger)
--
--    임시 개명 행(0033 §8): 이름은 owner_updated_at 으로 얼렸지만 **주소는 못
--    얼린다** — 주소는 인허가 데이터 영역이라 재적재가 항상 덮는다(의도된 정책,
--    20260715130000). 원 매장의 이전이 LOCALDATA 에 반영되는 순간 "새 가게 이름 +
--    옮겨간 주소" 라는 어긋난 행이 되는데, 지금은 재적재 때마다 사람이 기억해서
--    확인해야 한다. 어긋나는 그 UPDATE 순간에 알리면 기억할 필요가 없다.
--
--    특정 행 id 를 하드코딩하지 않는다 — owner_updated_at 을 가진 행 전부를 본다.
--    그 행들은 전부 "간판명·전화가 동결된 행" 이고, 동결된 이름 아래에서 주소가
--    움직이면 어느 행이든 사람이 봐야 한다. 같은 성격의 행이 늘어도 그대로 커버된다.
--
--    알람 실패가 재적재를 막으면 안 된다 — 이 트리거는 upsert_facilities 배치 안에서
--    돈다. trg_reports_alert(20260831061325)와 같은 예외 삼킴 패턴을 쓴다.

-- ── ② 동결 행 주소 변경 감지 ────────────────────────────────────────────

create function app.tg_facilities_frozen_addr_alert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform app.ops_alarm_fire(
    'facility_frozen_addr:' || new.id,
    1440,  -- 행별 하루 쿨다운 — 같은 배치를 다시 돌려도 하루 한 번만.
    '이름 동결 시설의 주소가 바뀜',
    format('%s — 재적재가 주소를 덮었습니다. 새 가게 분리 등록/이전 처리가 필요한지 확인하세요(0033 §8).', new.name),
    jsonb_build_object(
      'facility_id', new.id,
      'name', new.name,
      'old_address', old.address,
      'new_address', new.address
    )
  );
  return new;
exception when others then
  -- 알림 실패가 적재 배치 자체를 막으면 안 된다.
  raise warning 'tg_facilities_frozen_addr_alert failed: %', sqlerrm;
  return new;
end $$;

comment on function app.tg_facilities_frozen_addr_alert() is
  '이름 동결(owner_updated_at) 시설의 주소가 재적재로 덮이는 순간 관리자에게 알린다(0033 §8 임시 개명 행).';

create trigger trg_facilities_frozen_addr_alert
  after update on public.facilities
  for each row
  when (new.owner_updated_at is not null
        and new.address is distinct from old.address)
  execute function app.tg_facilities_frozen_addr_alert();

comment on trigger trg_facilities_frozen_addr_alert on public.facilities is
  '동결 행 주소 변경 감지 — 재적재 때마다 사람이 확인하던 것을 UPDATE 시점 알림으로 대체.';

-- ── ① 월간 재적재 리마인더 ──────────────────────────────────────────────
-- 매월 1일 00:00 UTC = 09:00 KST. 쿨다운 1일 — 수동 발화 시험과 겹쳐도 중복 없음.

do $$ begin
  if exists (select 1 from cron.job where jobname = 'facility-resync-reminder') then
    perform cron.unschedule('facility-resync-reminder');
  end if;
end $$;
select cron.schedule('facility-resync-reminder', '0 0 1 * *', $$
  select app.ops_alarm_fire(
    'facility_resync_due', 1440,
    '시설 데이터 월간 재적재',
    '재적재를 돌릴 때입니다 — 0033 §7 절차대로: CSV 4종(동물판매업 포함)·Excel 금지·최종수정시점 확인·--dry-run 먼저. 폐업·휴업 0건 파일은 필터본이니 쓰지 말 것.',
    jsonb_build_object('doc', '0033 §7')
  )
$$);
