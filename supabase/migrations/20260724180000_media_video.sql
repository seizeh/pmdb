-- ============================================================================
-- 영상 첨부 — 게시글(자유·소식) · 시설 후기 · 채팅
--
-- 표현 방식:
--  · posts/chat_messages: 기존 단일 미디어 슬롯 재사용 — image_url 에 영상 URL,
--    image_mime_type 'video/*', image_thumbnail_url 에 포스터(썸네일). 별도
--    컬럼 없음(피드·버블은 포스터를 그리고 재생은 상세/탭에서).
--  · facility_reviews: videos jsonb [{url, thumb_url, path?, ...}] 최대 2개
--    (사진 5장과 별도). 뷰어(share-view)는 poster+<video> 로 렌더.
--  · 크기 상한: 영상 100MB(사진 상한은 기존 유지 — posts 12MB, chat 10MB).
--    길이 제한(60초)·압축은 클라이언트 책임. media 버킷은 제한 없음(공개).
--  · 영상 게시글은 자유(free)·소식(news) 카테고리만 — 사진 인증 카테고리
--    (산책·돌봄·분양)는 실존 검증 파이프라인이 사진 전제라 제외(CHECK 강제,
--    원칙: 불변식은 DB 로).
-- ============================================================================

-- (1) posts — 영상 크기 상한 분리 + 영상 카테고리 제한
alter table public.posts drop constraint posts_image_file_size_check;
alter table public.posts add constraint posts_image_file_size_check
  check (image_file_size is null or image_file_size <=
         case when image_mime_type like 'video/%'
              then 104857600 else 12582912 end);
alter table public.posts add constraint posts_video_category_check
  check (image_mime_type is null
         or image_mime_type not like 'video/%'
         or category in ('free', 'news'));

-- (2) create_post_verified — p_image_thumb_url 추가(영상 포스터).
--     시그니처 변경이므로 구버전 drop 필수(오버로드 섀도잉).
drop function public.create_post_verified(
  character varying, character varying, text, timestamptz, uuid[],
  text, character varying, integer, uuid, double precision, double precision,
  character varying);
create function public.create_post_verified(
  p_category character varying,
  p_title character varying,
  p_content text,
  p_scheduled_at timestamp with time zone,
  p_pet_ids uuid[],
  p_image_url text,
  p_image_mime character varying,
  p_image_size integer,
  p_photo_token uuid default null,
  p_actual_lat double precision default null,
  p_actual_lng double precision default null,
  p_region_code character varying default null,
  p_image_thumb_url text default null
) returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_uid  uuid := app.uid();
  v_post uuid;
  v_pv   public.photo_verifications%rowtype;
  v_all_trusted boolean := false;
  v_user record;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

  -- 동네 인증 게이트 — 업체 모드(소식 전용)는 사업장 주소 기준이라 생략
  -- (승인 여부·지역 스탬프는 tg_posts_set_region 트리거가 강제).
  select region_code, is_location_verified, last_verified_at, active_mode
    into v_user
    from public.users where id = v_uid;
  if v_user.active_mode is distinct from 'business' then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if p_category in ('walk_together','walk_proxy','care','give_away') then
    v_all_trusted := p_pet_ids is not null
                 and array_length(p_pet_ids, 1) >= 1
                 and not exists (
                       select 1 from public.pets
                        where id = any(p_pet_ids) and trust_score < 3);

    if v_all_trusted then
      perform set_config('app.photo_trusted', 'true', true);
    else
      -- 미인증 펫 포함 → 사진 검증 필수. 촬영 대상은 연결 펫 중 아무나
      -- (한 마리 통과로 충분 — 인증된 펫을 촬영해도 된다).
      select * into v_pv from public.photo_verifications where id = p_photo_token;
      if not found or v_pv.pet_id is null then
        raise exception 'posts: 사진 검증 정보가 올바르지 않습니다';
      end if;
      if p_pet_ids is null or not (v_pv.pet_id = any(p_pet_ids)) then
        raise exception 'posts: 촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다';
      end if;
    end if;
  end if;

  perform set_config('app.photo_token', coalesce(p_photo_token::text, ''), true);

  insert into public.posts (
    user_id, category, title, content, scheduled_at,
    image_url, image_mime_type, image_file_size, image_thumbnail_url,
    actual_lat, actual_lng, region_code
  ) values (
    v_uid, p_category, p_title, p_content, p_scheduled_at,
    p_image_url, p_image_mime, p_image_size, p_image_thumb_url,
    p_actual_lat, p_actual_lng, p_region_code
  ) returning id into v_post;

  if p_pet_ids is not null and array_length(p_pet_ids, 1) >= 1 then
    insert into public.post_pets (post_id, pet_id)
      select v_post, unnest(p_pet_ids);
  end if;

  if v_pv.id is not null and v_pv.ai_matched then
    update public.pets set pet_match_count = pet_match_count + 1
     where id = v_pv.pet_id;
  end if;

  return v_post;
end;
$$;
revoke all on function public.create_post_verified(
  character varying, character varying, text, timestamptz, uuid[],
  text, character varying, integer, uuid, double precision, double precision,
  character varying, text) from public;
grant execute on function public.create_post_verified(
  character varying, character varying, text, timestamptz, uuid[],
  text, character varying, integer, uuid, double precision, double precision,
  character varying, text) to authenticated, service_role;

-- (3) update_my_post — 썸네일 인자 + 미디어 편집 허용 카테고리에 news 포함
--     (기존 free/adoption 만이던 것은 소식 이미지 편집 불가라는 비일관 — 정정).
drop function public.update_my_post(uuid, text, text, timestamptz, text,
  character varying, integer, boolean);
create function public.update_my_post(
  p_post uuid,
  p_title text,
  p_content text,
  p_scheduled_at timestamp with time zone default null,
  p_image_url text default null,
  p_image_mime character varying default null,
  p_image_size integer default null,
  p_edit_image boolean default false,
  p_image_thumb_url text default null
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_uid uuid := app.uid();
  v_owner uuid;
  v_old_sched timestamptz;
  v_cat text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_content), '') = '' then
    raise exception 'posts: 제목과 내용을 입력해주세요';
  end if;

  select user_id, scheduled_at, category into v_owner, v_old_sched, v_cat
  from public.posts where id = p_post for update;
  if v_owner is null then raise exception 'post_not_found'; end if;
  if v_owner <> v_uid then raise exception 'not_owner'; end if;

  update public.posts set
    title = btrim(p_title),
    content = btrim(p_content),
    scheduled_at = p_scheduled_at,
    edited_at = now(),
    image_url = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_url
      else image_url end,
    image_mime_type = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_mime
      else image_mime_type end,
    image_file_size = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_size
      else image_file_size end,
    image_thumbnail_url = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_thumb_url
      else image_thumbnail_url end
  where id = p_post;

  if v_old_sched is distinct from p_scheduled_at and p_scheduled_at is not null then
    insert into public.notifications(
      user_id, actor_user_id, notification_type, title, body, resource_type, resource_id
    )
    select a.applicant_id, v_uid, 'schedule_changed', '약속 일정이 변경됐어요',
           btrim(p_title) || ' — '
             || to_char(p_scheduled_at at time zone 'Asia/Seoul', 'MM월 DD일 HH24시') || ' 로 변경',
           'post', p_post
    from public.applications a
    where a.post_id = p_post and a.status in ('pending', 'accepted');
  end if;
end $$;
revoke all on function public.update_my_post(uuid, text, text, timestamptz, text,
  character varying, integer, boolean, text) from public;
grant execute on function public.update_my_post(uuid, text, text, timestamptz, text,
  character varying, integer, boolean, text) to authenticated, service_role;

-- (4) chat_messages — 영상 크기 상한 분리
alter table public.chat_messages drop constraint chat_messages_image_file_size_check;
alter table public.chat_messages add constraint chat_messages_image_file_size_check
  check (image_file_size is null or image_file_size <=
         case when image_mime_type like 'video/%'
              then 104857600 else 10485760 end);

-- (5) 채팅 미리보기·알림 본문 — 영상은 [동영상]
create or replace function app.tg_chat_messages_after_insert()
returns trigger
language plpgsql security definer
set search_path to ''
as $$
declare v_preview text;
begin
  if new.content is not null then v_preview := left(new.content, 100);
  elsif new.image_mime_type like 'video/%' then v_preview := '[동영상]';
  else v_preview := '[사진]'; end if;

  update public.chat_rooms
     set last_message_id = new.id, last_message_at = new.created_at, last_message_preview = v_preview
   where id = new.room_id;

  update public.users u
     set unread_chat_count = unread_chat_count + 1
    from public.chat_room_members m
   where m.room_id = new.room_id and m.user_id = u.id and m.user_id <> new.sender_id;

  insert into public.notifications(
    user_id, actor_user_id, notification_type, title, body, resource_type, resource_id
  )
  select m.user_id, new.sender_id, 'chat_message',
         coalesce(su.nickname, '새 메시지'), v_preview, 'chat_room', new.room_id
    from public.chat_room_members m
    left join public.users su on su.id = new.sender_id
   where m.room_id = new.room_id and m.user_id <> new.sender_id;

  return new;
end;
$$;

create or replace function public.delete_my_chat_message(p_message uuid)
returns void
language plpgsql security definer
set search_path to ''
as $$
declare
  v_uid uuid := app.uid();
  v_msg public.chat_messages%rowtype;
  v_next_id uuid;
  v_next_at timestamptz;
  v_next_preview text;
begin
  if v_uid is null then raise exception 'chat: 로그인이 필요합니다'; end if;

  select * into v_msg from public.chat_messages where id = p_message;
  if not found or v_msg.sender_id <> v_uid then
    raise exception 'chat: 내가 보낸 메시지만 삭제할 수 있어요';
  end if;
  if v_msg.is_deleted then return; end if;

  update public.chat_messages set is_deleted = true where id = p_message;

  update public.users u
     set unread_chat_count = greatest(u.unread_chat_count - 1, 0)
    from public.chat_room_members m
   where m.room_id = v_msg.room_id
     and m.user_id = u.id
     and m.user_id <> v_uid
     and (m.last_read_message_id is null
          or v_msg.created_at > (select lr.created_at
                                   from public.chat_messages lr
                                  where lr.id = m.last_read_message_id));

  if (select last_message_id from public.chat_rooms where id = v_msg.room_id)
     = p_message then
    select m.id, m.created_at,
           case when m.content is not null then left(m.content, 100)
                when m.image_mime_type like 'video/%' then '[동영상]'
                else '[사진]' end
      into v_next_id, v_next_at, v_next_preview
      from public.chat_messages m
     where m.room_id = v_msg.room_id and m.is_deleted = false
     order by m.created_at desc limit 1;
    update public.chat_rooms
       set last_message_id = v_next_id,
           last_message_at = coalesce(v_next_at, last_message_at),
           last_message_preview = coalesce(v_next_preview, '삭제된 메시지')
     where id = v_msg.room_id;
  end if;
end;
$$;

-- (6) 시설 후기 — videos jsonb [{url, thumb_url, ...}] 최대 2개
alter table public.facility_reviews
  add column videos jsonb not null default '[]';
alter table public.facility_reviews add constraint facility_reviews_videos_check
  check (jsonb_typeof(videos) = 'array' and jsonb_array_length(videos) <= 2);

-- (7) add_facility_review — p_videos 추가(시그니처 변경 — 구 6인자 drop)
drop function public.add_facility_review(uuid, smallint, text, text[], text[], boolean);
create function public.add_facility_review(
  p_facility uuid,
  p_rating smallint,
  p_body text,
  p_paths text[] default '{}',
  p_urls text[] default '{}',
  p_has_incentive boolean default false,
  p_videos jsonb default '[]'
) returns uuid
language plpgsql security definer
set search_path to ''
as $$
declare
  v_uid uuid := app.uid();
  v_id uuid;
  v jsonb;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;
  if exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_uid
       and bp.status in ('pending', 'approved')
       and bp.matched_facility_id = any(public.facility_sibling_ids(p_facility))
  ) then
    raise exception 'own_facility' using errcode = 'P0001';
  end if;
  -- 영상 검증 — 배열·개수는 CHECK 가 재검증하지만, 원소 형태는 여기서 명시 거부.
  if jsonb_typeof(coalesce(p_videos, '[]'::jsonb)) is distinct from 'array'
     or jsonb_array_length(coalesce(p_videos, '[]'::jsonb)) > 2 then
    raise exception 'invalid_videos' using errcode = 'P0001';
  end if;
  for v in select value from jsonb_array_elements(coalesce(p_videos, '[]'::jsonb))
  loop
    if jsonb_typeof(v) is distinct from 'object'
       or coalesce(v->>'url', '') = '' or length(v->>'url') > 500 then
      raise exception 'invalid_videos' using errcode = 'P0001';
    end if;
  end loop;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls,
     has_incentive, videos)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'),
          coalesce(p_has_incentive, false), coalesce(p_videos, '[]'::jsonb))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.add_facility_review(uuid, smallint, text, text[], text[], boolean, jsonb) from public;
grant execute on function public.add_facility_review(uuid, smallint, text, text[], text[], boolean, jsonb) to authenticated, service_role;

-- (8) 후기 조회 RPC — videos 반환 컬럼 추가(반환 타입 변경 — drop 필수)
drop function public.facility_reviews_of(uuid, integer, integer);
create function public.facility_reviews_of(
  p_facility uuid, p_limit integer default 20, p_offset integer default 0
) returns table (
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean, visit_no integer,
  has_incentive boolean, videos jsonb
)
language sql stable security definer
set search_path to ''
as $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no, r.has_incentive, r.videos
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.facility_id = any(public.facility_sibling_ids(p_facility))
         and fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$$;
revoke all on function public.facility_reviews_of(uuid, integer, integer) from public;
grant execute on function public.facility_reviews_of(uuid, integer, integer) to authenticated, service_role;

drop function public.facility_review_by_id(uuid);
create function public.facility_review_by_id(p_review uuid)
returns table (
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean, visit_no integer,
  has_incentive boolean, videos jsonb
)
language sql stable security definer
set search_path to ''
as $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no, r.has_incentive, r.videos
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.facility_id = any(public.facility_sibling_ids(
               (select facility_id from public.facility_reviews where id = p_review)))
         and fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
   where r.id = p_review;
$$;
revoke all on function public.facility_review_by_id(uuid) from public;
grant execute on function public.facility_review_by_id(uuid) to authenticated, service_role;

-- (9) 공유 뷰어 — 후기 videos 노출(뷰어는 poster+<video> 렌더)
create or replace function public.share_view_load(p_token varchar)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_link app.share_links%rowtype;
  v_out  jsonb;
begin
  select * into v_link from app.share_links where token = p_token;
  if not found or v_link.revoked_at is not null then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_link.expires_at < now() then
    return jsonb_build_object('status', 'expired');
  end if;

  update app.share_links set view_count = view_count + 1 where token = p_token;
  insert into app.funnel_events (event, token) values ('share_view', p_token);

  if v_link.kind = 'facility_preview' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'facility', jsonb_build_object(
        'name', f.name, 'category', f.category, 'address', f.address,
        'phone', f.phone, 'is_open', f.is_open,
        'avg_rating', f.avg_rating, 'review_count', f.review_count,
        'photo_url', bp.photo_url,
        'photo_align_y', coalesce(bp.photo_align_y, 0),
        'business_hours', bp.business_hours,
        'owner_verified', coalesce(bp.verified, false)),
      'reviews', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'rating', r.rating, 'content', r.content,
                 'has_incentive', r.has_incentive,
                 'photo_urls', r.photos,
                 'videos', r.videos)
                 order by r.has_media desc, r.created_at desc)
        from (select rating, content, has_incentive, created_at, videos,
                     coalesce(array_length(photo_urls, 1), 0) > 0
                       or jsonb_array_length(videos) > 0 as has_media,
                     (select coalesce(jsonb_agg(u), '[]'::jsonb)
                        from unnest(photo_urls[1:2]) u) as photos
              from public.facility_reviews
              where facility_id = f.id and visibility_status = 'visible'
              order by coalesce(array_length(photo_urls, 1), 0) > 0
                         or jsonb_array_length(videos) > 0 desc,
                       created_at desc
              limit 3) r), '[]'::jsonb))
    into v_out
    from public.facilities f
    left join lateral (
      select true as verified, b.photo_url, b.photo_align_y, b.business_hours
        from public.business_profiles b
       where b.status = 'approved'
         and b.matched_facility_id = any(public.facility_sibling_ids(f.id))
       order by b.reviewed_at nulls last
       limit 1
    ) bp on true
    where f.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  if v_link.kind = 'care_report' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'report', jsonb_build_object(
        'pet_label', r.pet_label, 'photos', r.photos, 'note', r.note,
        'kind', r.kind, 'body', r.body, 'created_at', r.created_at,
        'business_name', coalesce(b.storefront_name, b.business_name)))
    into v_out
    from app.care_reports r
    left join public.business_profiles b on b.user_id = r.business_id
    where r.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  if v_link.kind = 'starter' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'starter', jsonb_build_object(
        'business_name', coalesce(b.storefront_name, b.business_name)))
    into v_out
    from public.business_profiles b
    where b.user_id = v_link.ref_id and b.status = 'approved';
    return coalesce(v_out, jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'starter', jsonb_build_object('business_name', null)));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;
