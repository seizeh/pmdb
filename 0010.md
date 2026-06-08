-- ============================================================================
-- PawMate · 0010 · applications.status CHECK 보정
-- ----------------------------------------------------------------------------
-- 문제: 0002 의 applications.status CHECK 에 'completed' 가 빠져 있었음.
--   도메인 문서 14-2 매트릭스(accepted → completed, 시스템 처리)와 트리거
--   tg_appointments_after_update 가 동기화하려는 동작과 불일치 → 약속 완료 시
--   "violates check constraint applications_status_check" 발생.
-- 해결: CHECK 제약을 갈아끼워 'completed' 허용.
-- ============================================================================

alter table public.applications drop constraint if exists applications_status_check;
alter table public.applications
  add constraint applications_status_check
  check (status in ('pending','accepted','rejected','cancelled','completed'));
