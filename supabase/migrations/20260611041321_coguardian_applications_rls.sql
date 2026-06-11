-- 공동보호자도 지원자 목록 조회 + 수락(상태 변경)이 가능하도록 applications RLS 확장.
-- 기존: 지원자 본인 OR 게시글 작성자 OR admin → is_post_manager 로 통합(작성자+공동보호자 포함).

drop policy if exists applications_select on public.applications;
create policy applications_select on public.applications
  for select
  using (
    applicant_id = app.uid()
    or app.is_post_manager(post_id)
  );

drop policy if exists applications_update on public.applications;
create policy applications_update on public.applications
  for update
  using (
    applicant_id = app.uid()
    or app.is_post_manager(post_id)
  );
