-- 게시글 삭제 시 실좌표 즉시 파기("지체 없이" — 사업계획서 §3.4 / 위치기반서비스 이용약관 제8조④).
-- 소프트 삭제(visibility_status 전환)라 지금까지 actual_lat/lng 가 잔존했다. 삭제 RPC 에서
-- 좌표를 즉시 NULL 로 파기한다. retention-purge 배치는 백스톱(탈퇴자 게시글·누락분 커버).
-- CREATE OR REPLACE 이므로 기존 EXECUTE 권한(GRANT)은 유지된다.
create or replace function public.delete_my_post(p_post uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare v_owner uuid; v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;
  select user_id into v_owner from public.posts where id = p_post;
  if v_owner is null then
    raise exception 'posts: 게시글을 찾을 수 없습니다';
  end if;
  if v_owner <> v_uid then
    raise exception 'posts: 본인 게시글만 삭제할 수 있습니다';
  end if;
  update public.posts
     set visibility_status = 'deleted_by_user',
         actual_lat = null, actual_lng = null
   where id = p_post;
end;
$function$;

create or replace function public.admin_set_post_visibility(p_post uuid, p_visibility text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if p_visibility not in ('visible','hidden_by_admin','deleted_by_admin') then
    raise exception 'invalid_visibility' using errcode='P0001'; end if;
  if not exists (select 1 from public.posts where id=p_post) then
    raise exception 'post_not_found' using errcode='P0001'; end if;
  update public.posts
     set visibility_status = p_visibility,
         deleted_at = case when p_visibility like 'deleted_%' then now() else null end,
         -- 삭제 전이 시에만 좌표 파기(숨김은 복원 가능하므로 좌표 보존)
         actual_lat = case when p_visibility like 'deleted_%' then null else actual_lat end,
         actual_lng = case when p_visibility like 'deleted_%' then null else actual_lng end
   where id = p_post;
end;
$function$;
