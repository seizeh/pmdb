-- 채팅 삭제 30일 유예 하드삭제 + 관리자 대화 내역 조회.
--  (1) cleanup_retention: 소프트 삭제된 채팅 메시지를 30일 뒤 행 삭제
--      (신고 대응 기간 확보 후 파기 — 사용자 '삭제'의 무기한 보존 방지).
--      FK 는 last_message_id/last_read_message_id SET NULL, deletions CASCADE 라 안전.
--  (2) admin_get_report_target: chat_message 대상에 room_id 포함(대화 내역 진입용).
--  (3) admin_room_messages: 관리자 전용 방 전체 메시지(삭제분 포함) 조회 RPC.

create or replace function app.cleanup_retention()
returns void
language sql security definer set search_path to ''
as $function$
  delete from public.phone_verifications where created_at < now() - interval '1 day';

  delete from public.location_verifications where created_at < now() - interval '6 months';

  delete from public.photo_verifications pv
   where pv.created_at < now() - interval '6 months'
     and not exists (select 1 from public.pets  p  where p.ai_ref_verification_id = pv.id)
     and not exists (select 1 from public.posts po where po.photo_verification_id = pv.id);

  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where created_at < now() - interval '6 months'
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);

  update public.posts p
     set actual_lat = null, actual_lng = null
   where (p.visibility_status like 'deleted_%'
          or exists (select 1 from public.users u where u.id = p.user_id and u.status = 'deleted'))
     and (p.actual_lat is not null or p.actual_lng is not null);

  delete from public.post_views where viewed_at < now() - interval '3 months';

  -- ▼ 업체 인증 행 데이터 파기 (처리방침 §3 — 서류 파일은 purge-business-docs 가 담당)
  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '30 days'
     and exists (select 1 from public.users u
                  where u.id = bp.user_id and u.status = 'deleted');

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '6 months';

  -- ▼ 삭제된 채팅 메시지: 30일 유예 후 하드 삭제(신고 대응 기간 확보 후 파기).
  delete from public.chat_messages
   where is_deleted = true
     and coalesce(deleted_at, updated_at, created_at) < now() - interval '30 days';
$function$;

-- (2) 신고 대상(chat_message)에 room_id 포함 — 관리자 대화 내역 진입용.
create or replace function public.admin_get_report_target(p_report uuid)
returns json
language plpgsql stable security definer set search_path to ''
as $function$
declare
  v_type text; v_target uuid; v_out json;
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
      'room_id',m.room_id,
      'sender_nickname',coalesce(u.nickname,'알 수 없음'),'created_at',m.created_at)
    into v_out
    from public.chat_messages m left join public.users u on u.id=m.sender_id where m.id=v_target;
  end if;

  if v_out is null then
    v_out := json_build_object('kind', v_type, 'exists', false);
  end if;
  return v_out;
end;
$function$;

-- (3) 관리자 전용: 방 전체 메시지(삭제분 포함, 오래된 순).
create or replace function public.admin_room_messages(
  p_room uuid, p_limit integer default 200
)
returns table(
  id uuid, sender_id uuid, sender_nickname text, content text,
  image_url text, is_deleted boolean, deleted_at timestamptz,
  created_at timestamptz
)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
    select m.id, m.sender_id, coalesce(u.nickname, '알 수 없음')::text,
           m.content, m.image_url, m.is_deleted, m.deleted_at, m.created_at
      from public.chat_messages m
      left join public.users u on u.id = m.sender_id
     where m.room_id = p_room
     order by m.created_at asc
     limit least(coalesce(p_limit, 200), 500);
end;
$function$;

grant execute on function public.admin_room_messages(uuid, integer) to authenticated;
