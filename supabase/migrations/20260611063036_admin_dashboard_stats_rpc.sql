-- 관리자 대시보드 통계 RPC. app.is_admin() 이 아니면 거부.
-- (users.status/username 등은 컬럼 권한상 authenticated 에게 막혀 있어, 관리자 기능은 SECURITY DEFINER RPC 로 제공)
create or replace function public.admin_dashboard_stats()
 returns json
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare v json;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select json_build_object(
    'users',                  (select count(*) from public.users),
    'users_suspended',        (select count(*) from public.users where status = 'suspended'),
    'posts',                  (select count(*) from public.posts where deleted_at is null),
    'appointments_scheduled', (select count(*) from public.appointments where status = 'scheduled'),
    'reports_open',           (select count(*) from public.reports where status in ('submitted','reviewing'))
  ) into v;
  return v;
end;
$function$;

grant execute on function public.admin_dashboard_stats() to authenticated;
