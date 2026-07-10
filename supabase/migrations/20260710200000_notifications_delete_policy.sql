-- 본인 알림 삭제 허용 — 확인한 알림은 목록에서 제거(읽음 아카이빙 대신 삭제 UX).
-- 개별 탭 확인·모두 읽음 시 클라이언트가 삭제한다. 관리자도 삭제 가능(운영).
create policy notifications_delete on public.notifications
  for delete
  using (user_id = app.uid() or app.is_admin());
