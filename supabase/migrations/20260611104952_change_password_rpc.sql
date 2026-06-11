-- 로그인한 본인의 비밀번호 변경. 현재 비밀번호 확인 후 bcrypt 로 갱신.
create or replace function public.change_password(p_current text, p_new text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id uuid := app.uid();
begin
  if v_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_new is null or length(p_new) < 6 then
    raise exception 'weak_password' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.users
    where id = v_id
      and password_hash = extensions.crypt(p_current, password_hash)
  ) then
    raise exception 'invalid_current' using errcode = 'P0001';
  end if;
  update public.users
     set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 12))
   where id = v_id;
end;
$function$;

grant execute on function public.change_password(text, text) to authenticated;
