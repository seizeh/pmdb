-- posts/comments 는 기존 감사 트리거(tg_audit_posts/tg_audit_comments)가 admin_logs 를 남기므로
-- RPC 내부의 수동 admin_logs insert 를 제거(중복 로깅 방지).
create or replace function public.admin_set_post_visibility(p_post uuid, p_visibility text)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if p_visibility not in ('visible','hidden_by_admin','deleted_by_admin') then
    raise exception 'invalid_visibility' using errcode='P0001'; end if;
  if not exists (select 1 from public.posts where id=p_post) then
    raise exception 'post_not_found' using errcode='P0001'; end if;
  update public.posts
     set visibility_status=p_visibility,
         deleted_at = case when p_visibility like 'deleted_%' then now() else null end
   where id=p_post;
end;
$function$;

create or replace function public.admin_set_comment_deleted(p_comment uuid, p_deleted boolean)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists (select 1 from public.comments where id=p_comment) then
    raise exception 'comment_not_found' using errcode='P0001'; end if;
  update public.comments
     set is_deleted=p_deleted,
         deleted_at = case when p_deleted then now() else null end
   where id=p_comment;
end;
$function$;
