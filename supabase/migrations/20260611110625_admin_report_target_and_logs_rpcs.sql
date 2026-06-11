-- 신고 대상(게시글/댓글/회원/채팅메시지) 실제 내용 조회 + 채팅메시지 조치 + 감사 로그 조회.
create or replace function public.admin_get_report_target(p_report uuid)
returns json
language plpgsql stable security definer set search_path to ''
as $function$
declare v_type text; v_target uuid; v_out json;
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  select target_type, target_id into v_type, v_target from public.reports where id = p_report;
  if v_type is null then raise exception 'report_not_found' using errcode='P0001'; end if;

  if v_type = 'post' then
    select json_build_object('kind','post','exists',true,
      'id',p.id,'title',p.title,'content',p.content,
      'author_nickname',coalesce(u.nickname,'알 수 없음'),
      'visibility_status',p.visibility_status,'image_url',p.image_url,'created_at',p.created_at)
    into v_out
    from public.posts p left join public.users u on u.id=p.user_id where p.id=v_target;
  elsif v_type = 'comment' then
    select json_build_object('kind','comment','exists',true,
      'id',c.id,'content',c.content,'is_deleted',c.is_deleted,
      'author_nickname',coalesce(u.nickname,'알 수 없음'),
      'post_id',c.post_id,'post_title',pp.title,'created_at',c.created_at)
    into v_out
    from public.comments c
      left join public.users u on u.id=c.user_id
      left join public.posts pp on pp.id=c.post_id
    where c.id=v_target;
  elsif v_type = 'user' then
    select json_build_object('kind','user','exists',true,
      'id',u.id,'nickname',u.nickname,'username',u.username,
      'status',u.status,'user_type',u.user_type,'created_at',u.created_at)
    into v_out
    from public.users u where u.id=v_target;
  elsif v_type = 'chat_message' then
    select json_build_object('kind','chat_message','exists',true,
      'id',m.id,'content',m.content,'is_deleted',m.is_deleted,
      'sender_nickname',coalesce(u.nickname,'알 수 없음'),'created_at',m.created_at)
    into v_out
    from public.chat_messages m left join public.users u on u.id=m.sender_id where m.id=v_target;
  end if;

  if v_out is null then v_out := json_build_object('kind', v_type, 'exists', false); end if;
  return v_out;
end;
$function$;
grant execute on function public.admin_get_report_target(uuid) to authenticated;

create or replace function public.admin_set_chat_message_deleted(p_message uuid, p_deleted boolean)
returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists (select 1 from public.chat_messages where id=p_message) then
    raise exception 'message_not_found' using errcode='P0001'; end if;
  update public.chat_messages
     set is_deleted=p_deleted, deleted_at = case when p_deleted then now() else null end
   where id=p_message;
  insert into public.admin_logs(admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'set_chat_message_deleted', 'chat_message', p_message, jsonb_build_object('deleted', p_deleted));
end;
$function$;
grant execute on function public.admin_set_chat_message_deleted(uuid, boolean) to authenticated;

create or replace function public.admin_list_logs(p_limit int default 100, p_offset int default 0)
returns table (id uuid, admin_id uuid, admin_nickname text, action_type text,
  target_type text, target_id uuid, detail jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select l.id, l.admin_id, coalesce(u.nickname,'알 수 없음')::text, l.action_type::text,
         l.target_type::text, l.target_id, l.detail, l.created_at
  from public.admin_logs l
  left join public.users u on u.id = l.admin_id
  order by l.created_at desc
  limit greatest(1, least(coalesce(p_limit,100),200))
  offset greatest(0, coalesce(p_offset,0));
end;
$function$;
grant execute on function public.admin_list_logs(int,int) to authenticated;
