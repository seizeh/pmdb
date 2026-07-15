-- 업체 채팅 분리(컨텍스트 축) + 공개 프로필 업체 필드 (0025 후속 — 프로필 분리 4차).
--
-- 채팅: 같은 두 사람이라도 '개인 대화'와 '업체 문의'는 별개의 방이어야 한다
-- ("같은 계정, 분리된 프로필"). 방은 한번 섞이면 소급 분리가 불가능하므로
-- 생성 시점에 컨텍스트를 키에 포함한다. 업체 문의 방은 상대(업주)가 모드를
-- 바꿔도 상호로 표시되도록 business_profiles 에서 직접 이름을 읽는다.
--
-- 공개 프로필: 타사용자가 보는 업체 프로필 화면(상호·업종·주소·전화·시설 후기)을
-- 위해 업체 모드일 때만 사업장 공개 정보를 노출한다(사업장 정보는 공개 성격).

-- 1) 방 컨텍스트
alter table public.chat_rooms
  add column if not exists context varchar not null default 'personal'
    check (context in ('personal','business')),
  add column if not exists business_user_id uuid references public.users(id);

-- 2) start_direct_chat — 컨텍스트 파라미터. 시그니처 변경이라 구버전 DROP 필수
--    (오버로드 공존 시 PostgREST 가 구버전 호출).
drop function if exists public.start_direct_chat(uuid);

create function public.start_direct_chat(
  p_other uuid,
  p_context text default 'personal'
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_me uuid := app.uid();
  v_key text;
  v_room uuid;
  v_left_exists boolean;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = 'P0001'; end if;
  if p_other is null or p_other = v_me then raise exception 'invalid_target' using errcode = 'P0001'; end if;
  if p_context not in ('personal', 'business') then
    raise exception 'invalid_context' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.users where id = p_other and status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;
  -- 업체 문의는 상대가 승인된 업체일 때만
  if p_context = 'business' and not exists (
    select 1 from public.business_profiles bp
     where bp.user_id = p_other and bp.status = 'approved'
  ) then
    raise exception 'not_a_business' using errcode = 'P0001';
  end if;

  -- 두 사용자 정렬로 결정적 canonical_key — 업체 문의는 키에 컨텍스트(업체 당사자)를
  -- 포함해 개인 방과 별개의 방이 된다.
  v_key := 'direct:' || least(v_me, p_other)::text || ':' || greatest(v_me, p_other)::text
           || case when p_context = 'business' then ':biz:' || p_other::text else '' end;

  select id into v_room from public.chat_rooms
   where canonical_key = v_key
   for update;

  if v_room is not null then
    select exists (
      select 1 from public.chat_room_members m
      where m.room_id = v_room and m.left_at is not null
    ) into v_left_exists;
    if v_left_exists then
      update public.chat_rooms
         set canonical_key = v_key || ':closed:' || v_room::text
       where id = v_room;
      v_room := null;
    end if;
  end if;

  if v_room is null then
    insert into public.chat_rooms(room_type, canonical_key, context, business_user_id)
      values ('direct', v_key, p_context,
              case when p_context = 'business' then p_other end)
      on conflict (canonical_key) do nothing
      returning id into v_room;
    if v_room is null then
      select id into v_room from public.chat_rooms where canonical_key = v_key;
    end if;
  end if;

  insert into public.chat_room_members(room_id, user_id)
    select v_room, t.x
    from (values (v_me), (p_other)) as t(x)
    where not exists (
      select 1 from public.chat_room_members m
      where m.room_id = v_room and m.user_id = t.x
    );

  return v_room;
end;
$function$;

revoke all on function public.start_direct_chat(uuid, text) from public, anon;
grant execute on function public.start_direct_chat(uuid, text) to authenticated;

-- 3) v_chat_rooms — 업체 문의 방은 상대(업주)를 상호로 표시 + context 노출.
--    상호는 business_profiles(approved)에서 직접 읽어 업주가 개인 모드로 돌아가도 유지.
create or replace view public.v_chat_rooms as
 select r.id,
    r.last_message_preview,
    r.last_message_at,
    coalesce(( select case when r.context = 'business' and m2.user_id = r.business_user_id
                           then coalesce(bp.business_name, pr.nickname::text)
                           else pr.nickname::text end
           from chat_room_members m2
             join public_profiles pr on pr.id = m2.user_id
             join users u2 on u2.id = m2.user_id
             left join business_profiles bp
               on bp.user_id = m2.user_id and bp.status = 'approved'
          where m2.room_id = r.id and m2.user_id <> app.uid()
            and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
         limit 1),
        case
            when r.room_type::text = 'admin_inquiry'::text then '고객센터'::text
            else '알 수 없음'::text
        end) as other_nickname,
    ( select m2.user_id
           from chat_room_members m2
             join users u2 on u2.id = m2.user_id
          where m2.room_id = r.id and m2.user_id <> app.uid()
            and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
         limit 1) as other_user_id,
    ( select count(*) as count
           from chat_messages cm
          where cm.room_id = r.id and cm.is_deleted = false and cm.sender_id <> app.uid()
            and (m.last_read_message_id is null or cm.created_at > (( select lr.created_at
                   from chat_messages lr
                  where lr.id = m.last_read_message_id)))) as unread_count,
    (exists ( select 1
           from chat_room_members m3
          where m3.room_id = r.id and m3.user_id <> app.uid() and m3.left_at is not null)) as other_left,
    ( select pr.profile_image_url
           from chat_room_members m2
             join public_profiles pr on pr.id = m2.user_id
             join users u2 on u2.id = m2.user_id
          where m2.room_id = r.id and m2.user_id <> app.uid()
            and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
         limit 1) as other_profile_image_url,
    r.context
   from chat_room_members m
     join chat_rooms r on r.id = m.room_id
  where m.user_id = app.uid() and m.left_at is null;

-- 4) public_profiles — 업체 모드 계정의 사업장 공개 정보(타사용자 업체 프로필 화면용)
create or replace view public.public_profiles as
  select u.id, u.nickname, u.user_type, u.profile_image_url, u.profile_image_thumbnail_url,
         u.address, u.is_location_verified, u.created_at, u.activity_radius_m,
         coalesce(bp.status = 'approved', false) as is_business,
         case when u.active_mode = 'business' and bp.status = 'approved'
              then bp.business_name end as business_name,
         case when u.active_mode = 'business' and bp.status = 'approved'
              then bp.declared_category end as business_category,
         case when u.active_mode = 'business' and bp.status = 'approved'
              then bp.business_address end as business_address,
         case when u.active_mode = 'business' and bp.status = 'approved'
              then bp.business_phone end as business_phone,
         case when u.active_mode = 'business' and bp.status = 'approved'
              then bp.matched_facility_id end as business_facility_id
    from public.users u
    left join public.business_profiles bp on bp.user_id = u.id;
