-- 신고 중복 방지 — 같은 신고자가 같은 대상에 처리 중(open)인 신고를 중복 생성하지 못하게 한다.
--
-- '처리 중'(submitted/reviewing)일 때만 막는 부분 유니크 인덱스다.
-- resolved/dismissed 로 종료된 뒤에는 재신고가 가능해야 하므로 status 조건을 둔다.
-- 클라이언트 INSERT(reports_insert RLS) 시 중복이면 23505(unique_violation)로 거절되고,
-- 앱(report_repository)은 이를 "이미 신고한 대상" 안내로 변환한다.
create unique index if not exists reports_one_open_per_target
  on public.reports (reporter_id, target_type, target_id)
  where status in ('submitted', 'reviewing');

comment on index public.reports_one_open_per_target is
  '신고자별 대상당 처리 중(open) 신고 1건 제한. 종료(resolved/dismissed) 후 재신고 허용';
