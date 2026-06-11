-- 관리자 신고 처리 RPC (is_admin 게이트).
create or replace function public.admin_list_reports(
  p_status text default 'open',
  p_limit  int  default 50,
  p_offset int  default 0
)
returns table (
  id uuid, target_type text, target_id uuid, categories text[],
  extra_description text, status text, created_at timestamptz,
  reviewed_at timestamptz, reporter_id uuid, reporter_nickname text
)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select r.id, r.target_type::text, r.target_id, r.categories,
         r.extra_description, r.status::text, r.created_at, r.reviewed_at,
         r.reporter_id, coalesce(u.nickname,'알 수 없음')::text
  from public.reports r
  left join public.users u on u.id = r.reporter_id
  where (p_status is null)
     or (p_status = 'open' and r.status in ('submitted','reviewing'))
     or (p_status not in ('open') and r.status = p_status)
  order by r.created_at desc
  limit greatest(1, least(coalesce(p_limit,50),100))
  offset greatest(0, coalesce(p_offset,0));
end;
$function$;
grant execute on function public.admin_list_reports(text,int,int) to authenticated;

create or replace function public.admin_set_report_status(p_report uuid, p_status text)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if p_status not in ('submitted','reviewing','resolved','dismissed') then
    raise exception 'invalid_status' using errcode='P0001'; end if;
  if not exists (select 1 from public.reports where id=p_report) then
    raise exception 'report_not_found' using errcode='P0001'; end if;
  update public.reports
     set status=p_status, reviewed_by=app.uid(), reviewed_at=now()
   where id=p_report;
  insert into public.admin_logs(admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'set_report_status', 'report', p_report, jsonb_build_object('status', p_status));
end;
$function$;
grant execute on function public.admin_set_report_status(uuid, text) to authenticated;
