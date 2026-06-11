-- 관리자 게시글/댓글 관리 RPC (is_admin 게이트).
create or replace function public.admin_list_posts(
  p_search text default null, p_limit int default 50, p_offset int default 0
)
returns table (
  id uuid, title text, content text, category text,
  author_id uuid, author_nickname text, visibility_status text,
  heart_count int, comment_count int, view_count int, created_at timestamptz
)
language plpgsql stable security definer set search_path to ''
as $function$
declare v_q text := nullif(btrim(coalesce(p_search,'')), '');
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select p.id, p.title::text, left(p.content,140), p.category::text,
         p.user_id, coalesce(u.nickname,'알 수 없음')::text, p.visibility_status::text,
         p.heart_count, p.comment_count, p.view_count, p.created_at
  from public.posts p
  left join public.users u on u.id = p.user_id
  where v_q is null or p.title ilike '%'||v_q||'%' or p.content ilike '%'||v_q||'%'
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit,50),100))
  offset greatest(0, coalesce(p_offset,0));
end;
$function$;
grant execute on function public.admin_list_posts(text,int,int) to authenticated;

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
  insert into public.admin_logs(admin_id, action_type, target_type, target_id, detail)
  values (app.uid(),'set_post_visibility','post',p_post, jsonb_build_object('visibility',p_visibility));
end;
$function$;
grant execute on function public.admin_set_post_visibility(uuid, text) to authenticated;

create or replace function public.admin_list_comments(p_post uuid)
returns table (id uuid, content text, author_id uuid, author_nickname text, is_deleted boolean, created_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select c.id, c.content, c.user_id, coalesce(u.nickname,'알 수 없음')::text, c.is_deleted, c.created_at
  from public.comments c
  left join public.users u on u.id = c.user_id
  where c.post_id = p_post
  order by c.created_at asc;
end;
$function$;
grant execute on function public.admin_list_comments(uuid) to authenticated;

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
  insert into public.admin_logs(admin_id, action_type, target_type, target_id, detail)
  values (app.uid(),'set_comment_deleted','comment',p_comment, jsonb_build_object('deleted',p_deleted));
end;
$function$;
grant execute on function public.admin_set_comment_deleted(uuid, boolean) to authenticated;
