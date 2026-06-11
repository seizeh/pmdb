-- 관리자 회원 관리 RPC (is_admin 게이트).
-- users.username/status/phone 은 authenticated 컬럼 권한에서 막혀 있어 RPC 로 제공.

create or replace function public.admin_list_users(
  p_search text default null,
  p_limit  int  default 50,
  p_offset int  default 0
)
returns table (
  id uuid, username text, nickname text, user_type text,
  status text, phone text, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare v_q text := nullif(btrim(coalesce(p_search,'')), '');
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select u.id, u.username::text, u.nickname::text, u.user_type::text,
         u.status::text, u.phone::text, u.created_at
  from public.users u
  where v_q is null
     or u.username ilike '%'||v_q||'%'
     or u.nickname ilike '%'||v_q||'%'
     or u.phone    ilike '%'||v_q||'%'
  order by u.created_at desc
  limit greatest(1, least(coalesce(p_limit,50), 100))
  offset greatest(0, coalesce(p_offset,0));
end;
$function$;

grant execute on function public.admin_list_users(text,int,int) to authenticated;

-- 회원 상태 변경 (active/inactive/suspended). 본인/다른 관리자에는 적용 불가. 감사로그 기록.
create or replace function public.admin_set_user_status(p_user uuid, p_status text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare v_type text;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('active','inactive','suspended') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  if p_user = app.uid() then
    raise exception 'cannot_modify_self' using errcode = 'P0001';
  end if;
  select user_type into v_type from public.users where id = p_user;
  if v_type is null then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;
  if v_type = 'admin' then
    raise exception 'cannot_modify_admin' using errcode = 'P0001';
  end if;

  update public.users set status = p_status where id = p_user;

  insert into public.admin_logs(admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'set_user_status', 'user', p_user, jsonb_build_object('status', p_status));
end;
$function$;

grant execute on function public.admin_set_user_status(uuid, text) to authenticated;
