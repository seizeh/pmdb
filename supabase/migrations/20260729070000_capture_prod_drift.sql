-- 운영 DB 드리프트 포착 — 마이그레이션 없이 직접 적용됐던 정의를 저장소로 되돌린다.
--
-- 새로 만든 리플레이 CI(db-tests.yml 의 replay 잡)가 빈 DB 에 baseline + 마이그레이션을
-- 쌓아 스냅샷과 대조하면서 찾아낸 차이다. 여기 담긴 정의는 전부 supabase/schema/schema.sql
-- (= 운영 DB 덤프)에서 그대로 가져왔으므로, 운영에 적용해도 결과가 바뀌지 않는다(no-op).
-- 목적은 '빈 DB 에서 재생했을 때도 운영과 같은 스키마가 나오게' 하는 것이다.
--
-- 확인된 것 중 눈여겨볼 두 가지:
--
--  1) app.dispatch_engagement_notifications 의 pawings 조인에서
--       and w.context = p.authored_as   -- 같은 얼굴 팔로워만
--     이 빠져 있었다. 20260718160000 이 넣은 조건을 20260720090000 의
--     create or replace 가 조용히 지운 것이다(운영에는 살아 있다). 저장소만 보고
--     재생하면 업체 소식이 개인 팔로워에게도 가는 상태가 된다.
--
--  2) 간이 회원(status='lite') 관련 정의가 통째로 저장소 밖에 있었다 —
--     users_status_check 의 'lite', add_facility_review 의 app.uid_lite()/재인증 게이트,
--     후기 조회의 전화번호 마스킹 등.
--
-- 앞으로는 replay 잡이 이런 차이를 즉시 실패로 잡는다.


-- ── users: status 'lite' 허용 ─────────────────────────────────────────────
alter table public.users drop constraint if exists users_status_check;
alter table public.users add constraint users_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying, 'suspended'::character varying, 'deleted'::character varying, 'lite'::character varying])::text[])));

-- ── 함수 정의 ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION app.cleanup_auth() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  delete from app.refresh_tokens
   where absolute_expires_at < now()
      or (revoked_at is not null and revoked_at < now() - interval '1 day')
      or (revoked_at is null and expires_at < now() - interval '1 day');
  delete from app.rate_limits where expires_at < now();
$$;
REVOKE ALL ON FUNCTION app.cleanup_auth() FROM PUBLIC;

CREATE OR REPLACE FUNCTION app.cleanup_retention() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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

  delete from app.auth_logs where created_at < now() - interval '3 months';

  delete from app.location_usage_logs where used_at < now() - interval '6 months';

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '30 days'
     and exists (select 1 from public.users u
                  where u.id = bp.user_id and u.status = 'deleted');

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '6 months';

  delete from public.chat_messages
   where is_deleted = true
     and coalesce(deleted_at, updated_at, created_at) < now() - interval '30 days';
$$;
REVOKE ALL ON FUNCTION app.cleanup_retention() FROM PUBLIC;

CREATE OR REPLACE FUNCTION app.dispatch_engagement_notifications() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_grace interval := interval '90 seconds';
begin
  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select p.user_id, h.user_id, 'post_heart',
         '❤️ ' || u.nickname || '님이 회원님의 게시글을 좋아해요',
         app.notif_trunc(p.title), 'post', p.id
    from public.post_hearts h
    join public.posts p on p.id = h.post_id and p.deleted_at is null
    join public.users u on u.id = h.user_id
   where not h.notified
     and h.created_at <= now() - v_grace
     and p.user_id <> h.user_id
     and not exists (
       select 1 from public.notifications n
        where n.notification_type = 'post_heart'
          and n.user_id = p.user_id and n.actor_user_id = h.user_id
          and n.resource_id = p.id);
  update public.post_hearts set notified = true
   where not notified and created_at <= now() - v_grace;

  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, resource_type, resource_id)
  select w.following_id, w.follower_id, 'pawing_follow',
         '🐾 ' || u.nickname || '님이 회원님을 Pawing 하기 시작했어요',
         'user', w.follower_id
    from public.pawings w
    join public.users u on u.id = w.follower_id
   where not w.notified
     and w.created_at <= now() - v_grace
     and not exists (
       select 1 from public.notifications n
        where n.notification_type = 'pawing_follow'
          and n.user_id = w.following_id and n.actor_user_id = w.follower_id);
  update public.pawings set notified = true
   where not notified and created_at <= now() - v_grace;

  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select w.follower_id, p.user_id, 'pawing_new_post',
         '📝 ' || case when p.authored_as = 'business'
              then coalesce(bp.business_name, u.nickname)
              else u.nickname end || '님이 새 게시글을 올렸어요',
         app.notif_trunc(p.title), 'post', p.id
    from public.posts p
    join public.users u on u.id = p.user_id
    left join public.business_profiles bp
      on bp.user_id = p.user_id and bp.status = 'approved'
    join public.pawings w on w.following_id = p.user_id
                         and w.context = p.authored_as
   where not p.pawing_notified
     and p.created_at <= now() - v_grace
     and p.deleted_at is null
     and w.follower_id <> p.user_id
     and not exists (
       select 1 from public.notifications n
        where n.user_id = w.follower_id and n.resource_id = p.id
          and n.notification_type in ('pawing_new_post', 'pet_in_post'));
  update public.posts set pawing_notified = true
   where not pawing_notified and created_at <= now() - v_grace;
end;
$$;

CREATE OR REPLACE FUNCTION app.tg_applications_on_accept() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_post       public.posts%rowtype;
  v_locked_id  uuid;
  v_conflict   int;
  v_actor      uuid;
  v_owner_side uuid;
begin
  if not (old.status = 'pending' and new.status = 'accepted') then
    return new;
  end if;

  select * into v_post from public.posts where id = new.post_id for update;
  if v_post.id is null then
    raise exception 'applications: 게시글이 존재하지 않습니다';
  end if;

  -- 이 application 의 관련 펫 = post_pets ∪ {offered_pet_id} 가 다른 scheduled 약속에 잡혀 있나
  with new_pets as (
    select pp.pet_id from public.post_pets pp where pp.post_id = new.post_id
    union
    select new.offered_pet_id where new.offered_pet_id is not null
  )
  select count(*) into v_conflict
    from public.appointments a2
   where a2.status = 'scheduled'
     and (
       exists (
         select 1 from public.post_pets pp2
          where pp2.post_id = a2.post_id and pp2.pet_id in (select pet_id from new_pets)
       )
       or exists (
         select 1 from public.applications app2
          where app2.id = a2.application_id
            and app2.offered_pet_id is not null
            and app2.offered_pet_id in (select pet_id from new_pets)
       )
     );
  if v_conflict > 0 then
    raise exception '이 반려동물은 이미 다른 약속이 진행 중입니다. 해당 약속을 완료/취소한 뒤 수락해주세요';
  end if;

  update public.posts
     set progress_status = 'matched'
   where id = new.post_id and progress_status = 'recruiting'
  returning id into v_locked_id;
  if v_locked_id is null then
    raise exception '다른 사용자가 먼저 수락하였습니다';
  end if;

  -- 약속의 보호자 측 = 실제 수락한 사람.
  -- 작성자 본인 또는 게시글 펫의 공동보호자가 수락하면 그 사람이 약속 당사자가 된다.
  -- (admin 등 보호자가 아닌 주체가 수락한 예외는 작성자로 fallback)
  v_actor := app.uid();
  if v_actor is not null and (
       v_actor = v_post.user_id
       or exists (
         select 1
           from public.post_pets pp
           join public.pet_guardians g on g.pet_id = pp.pet_id
          where pp.post_id = new.post_id and g.user_id = v_actor
       )
     ) then
    v_owner_side := v_actor;
  else
    v_owner_side := v_post.user_id;
  end if;

  insert into public.appointments
    (application_id, post_id, post_owner_id, applicant_id, status, scheduled_at)
  values
    (new.id, new.post_id, v_owner_side, new.applicant_id, 'scheduled', v_post.scheduled_at);

  -- 나머지 대기 지원자 자동 거절
  update public.applications
     set status = 'rejected'
   where post_id = new.post_id
     and id <> new.id
     and status = 'pending';

  -- 공동보호자가 작성자 대신 수락한 경우, 작성자에게 알림 (작성자는 약속 당사자가 아님 = 평가 불가)
  if v_owner_side is distinct from v_post.user_id then
    begin
      insert into public.notifications
        (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
      values
        (v_post.user_id, v_actor, 'application_accepted_by_co',
         '공동보호자가 지원을 수락했어요',
         '내 게시글의 지원이 공동보호자에 의해 수락되었습니다',
         'post', new.post_id);
    exception when others then null;
    end;
  end if;

  return new;
end;
$$;

CREATE OR REPLACE FUNCTION app.tg_notify_pet_in_post() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_author uuid;
  v_title  text;
  v_pet    text;
  v_actor  text;
begin
  select p.user_id, p.title into v_author, v_title
    from public.posts p where p.id = new.post_id;
  if v_author is null then return new; end if;

  select pt.name into v_pet from public.pets pt where pt.id = new.pet_id;
  select u.nickname into v_actor from public.users u where u.id = v_author;

  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select g.user_id, v_author, 'pet_in_post',
         '🐾 ' || coalesce(v_actor, '누군가') || '님이 '
              || coalesce(v_pet, '반려동물') || '(을)를 게시글에 등록했어요',
         app.notif_trunc(v_title), 'post', new.post_id
    from public.pet_guardians g
   where g.pet_id = new.pet_id
     and g.user_id <> v_author
     and not exists (
       select 1 from public.notifications n
        where n.notification_type = 'pet_in_post'
          and n.user_id = g.user_id and n.resource_id = new.post_id);
  return new;
end;
$$;

CREATE OR REPLACE FUNCTION app.tg_posts_check_write() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_user_type text;
  v_cnt       int;
  v_token     uuid := nullif(current_setting('app.photo_token', true), '')::uuid;
  v_pv        public.photo_verifications%rowtype;
begin
  select user_type into v_user_type from public.users where id = new.user_id;
  if v_user_type is null then
    raise exception 'posts: 존재하지 않는 작성자';
  end if;

  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if v_user_type <> 'pet_owner' then
      raise exception 'posts: % 카테고리는 pet_owner 만 작성 가능', new.category;
    end if;
  end if;

  if new.category = 'give_away' then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and g.role = 'owner' and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: 분양은 본인이 소유자(owner)인 활성 반려동물이 있어야 작성 가능';
    end if;
  elsif new.category in ('walk_together','walk_proxy','care') then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: % 카테고리는 보호 중인 활성 반려동물이 있어야 작성 가능', new.category;
    end if;
  end if;

  if new.category in ('walk_together','walk_proxy','care') and new.scheduled_at is null then
    raise exception 'posts: % 카테고리는 약속 일정(scheduled_at) 필수', new.category;
  end if;
  if new.category in ('give_away','adoption') and new.scheduled_at is not null then
    raise exception 'posts: % 카테고리는 게시 시 약속 일정을 둘 수 없음', new.category;
  end if;

  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if coalesce(current_setting('app.photo_trusted', true), '') = 'true' then
      new.is_pet_verified := true;
    else
      if new.image_url is null then
        raise exception 'posts: % 카테고리는 사진 등록이 필요합니다', new.category;
      end if;
      if v_token is null then
        raise exception 'posts: 사진 실존 검증이 필요합니다';
      end if;
      select * into v_pv from public.photo_verifications
        where id = v_token
          and user_id = new.user_id
          and purpose = 'post'
          and pet_id is not null
          and result = 'pass'
          and ai_pass = true
          and region_matched = true
          and consumed_at is null
          and expires_at > now()
          and image_url = new.image_url;
      if not found then
        raise exception 'posts: 유효하지 않거나 만료된 사진 검증입니다';
      end if;

      update public.photo_verifications set consumed_at = now() where id = v_pv.id;
      new.photo_verification_id := v_pv.id;
      new.ai_pet_species        := v_pv.ai_species;
      new.is_pet_verified       := v_pv.ai_matched;
    end if;
  end if;

  return new;
end;
$$;

CREATE OR REPLACE FUNCTION app.tg_posts_set_region() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_user record;
  v_biz  record;
  v_parts text[];
  v_dong text;
begin
  if new.authored_as = 'business' then
    select business_region_code,
           coalesce(business_address_jibun, business_address) as addr
      into v_biz
      from public.business_profiles
     where user_id = new.user_id and status = 'approved';
    if not found then
      raise exception 'posts: 승인된 업체만 소식을 작성할 수 있어요';
    end if;
    if new.region_code is null then
      new.region_code := coalesce(
        v_biz.business_region_code,
        (select region_code from public.users where id = new.user_id));
    end if;
    if new.display_address is null and v_biz.addr is not null then
      select t into v_dong
        from unnest(regexp_split_to_array(btrim(v_biz.addr), '\s+'))
             with ordinality as u(t, ord)
       where t ~ '(동|읍|면|가|리)$'
       order by ord limit 1;
      new.display_address := v_dong;
    end if;
    return new;
  end if;

  select region_code, address, is_location_verified, last_verified_at
    into v_user
    from public.users where id = new.user_id;

  if not app.is_admin() then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if new.region_code is null then
    new.region_code := v_user.region_code;
  end if;

  if new.display_address is null and v_user.address is not null
     and length(btrim(v_user.address)) > 0 then
    v_parts := regexp_split_to_array(btrim(v_user.address), '\s+');
    new.display_address := v_parts[cardinality(v_parts)];
  end if;
  return new;
end $_$;

CREATE OR REPLACE FUNCTION app.tg_reviews_grant_pet_trust() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_post uuid;
begin
  update public.appointments
     set trust_awarded = true
   where id = new.appointment_id
     and status = 'completed'
     and trust_awarded = false
  returning post_id into v_post;

  if v_post is not null then
    update public.pets p
       set trust_score = p.trust_score + 1
     where p.id in (select pp.pet_id from public.post_pets pp where pp.post_id = v_post);
  end if;
  return new;
end $$;

CREATE OR REPLACE FUNCTION public.add_facility_review(p_facility uuid, p_rating smallint, p_body text, p_paths text[] DEFAULT '{}'::text[], p_urls text[] DEFAULT '{}'::text[], p_has_incentive boolean DEFAULT false, p_videos jsonb DEFAULT '[]'::jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid    uuid := app.uid_lite();
  v_id     uuid;
  v        jsonb;
  v_status text;
  v_phone  text;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;

  select status, phone into v_status, v_phone
    from public.users where id = v_uid;

  -- 간이 회원은 후기 한 건마다 전화 인증을 새로 받는다(세션을 들고 다니지 않는다).
  if v_status = 'lite' then
    if not exists (
      select 1 from public.phone_verifications
      where phone = v_phone
        and purpose = 'review'
        and is_used = true
        and created_at > now() - interval '15 minutes'
    ) then
      raise exception 'reverify_required' using errcode = 'P0001';
    end if;
  end if;

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

CREATE OR REPLACE FUNCTION public.admin_create_facility_share_link(p_facility uuid, p_days integer DEFAULT 365) RETURNS TABLE(token character varying, expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_token varchar(32);
  v_exp   timestamptz;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_days < 1 or p_days > 3650 then
    raise exception 'days 1..3650';
  end if;
  if not exists (select 1 from public.facilities f where f.id = p_facility) then
    raise exception 'facility not found';
  end if;

  select l.token, l.expires_at into v_token, v_exp
  from app.share_links l
  where l.kind = 'facility_preview' and l.ref_id = p_facility
    and l.revoked_at is null and l.expires_at > now()
  order by l.created_at desc limit 1;
  if v_token is not null then
    return query select v_token, v_exp;
    return;
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp   := now() + make_interval(days => p_days);
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'facility_preview', p_facility, app.uid(), v_exp);
  return query select v_token, v_exp;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_comments(p_post uuid) RETURNS TABLE(id uuid, content text, author_id uuid, author_nickname text, is_deleted boolean, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select c.id, c.content, c.user_id, coalesce(u.nickname,'알 수 없음')::text,
         c.is_deleted, c.created_at
  from public.comments c
  left join public.users u on u.id = c.user_id
  where c.post_id = p_post
  order by c.created_at asc;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_inquiries() RETURNS TABLE(room_id uuid, user_id uuid, user_nickname text, last_message text, last_message_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select r.id,
         inq.user_id,
         coalesce(u.nickname, '알 수 없음')::text,
         r.last_message_preview::text,
         r.last_message_at
  from public.chat_rooms r
  left join lateral (
    select m.user_id
    from public.chat_room_members m
    join public.users uu on uu.id = m.user_id
    where m.room_id = r.id and uu.user_type <> 'admin'
    limit 1
  ) inq on true
  left join public.users u on u.id = inq.user_id
  where r.room_type = 'admin_inquiry'
  order by r.last_message_at desc nulls last;
end;
$$;
REVOKE ALL ON FUNCTION public.admin_list_inquiries() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_inquiries() TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_inquiries() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_list_posts(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, title text, content text, category text, author_id uuid, author_nickname text, visibility_status text, heart_count integer, comment_count integer, view_count integer, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_q text := nullif(btrim(coalesce(p_search,'')), '');
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select p.id, p.title::text, left(p.content, 140), p.category::text,
         p.user_id, coalesce(u.nickname,'알 수 없음')::text, p.visibility_status::text,
         p.heart_count, p.comment_count, p.view_count, p.created_at
  from public.posts p
  left join public.users u on u.id = p.user_id
  where v_q is null or p.title ilike '%'||v_q||'%' or p.content ilike '%'||v_q||'%'
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit,50),100))
  offset greatest(0, coalesce(p_offset,0));
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_reports(p_status text DEFAULT 'open'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, target_type text, target_id uuid, categories text[], extra_description text, status text, created_at timestamp with time zone, reviewed_at timestamp with time zone, reporter_id uuid, reporter_nickname text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select r.id, r.target_type::text, r.target_id, r.categories,
         r.extra_description, r.status::text, r.created_at, r.reviewed_at,
         r.reporter_id, coalesce(u.nickname, '알 수 없음')::text
  from public.reports r
  left join public.users u on u.id = r.reporter_id
  where (p_status is null)
     or (p_status = 'open'  and r.status in ('submitted','reviewing'))
     or (p_status not in ('open') and r.status = p_status)
  order by r.created_at desc
  limit greatest(1, least(coalesce(p_limit,50), 100))
  offset greatest(0, coalesce(p_offset,0));
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_ops_metrics() RETURNS json
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  c_sms_krw numeric := 9;
  c_ai_krw  numeric := 20;
  tz        text := 'Asia/Seoul';
  today_kst date := (now() at time zone tz)::date;
  v json;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  with pv as (select created_at, result from public.photo_verifications),
  ph as (select created_at from public.phone_verifications),
  act as (
    select user_id,     issued_at  as ts from app.refresh_tokens        where user_id is not null
    union all select sender_id,    created_at from public.chat_messages
    union all select user_id,      created_at from public.comments
    union all select user_id,      created_at from public.posts
    union all select user_id,      created_at from public.post_hearts
    union all select applicant_id, created_at from public.applications
    union all select reviewer_id,  created_at from public.reviews
    union all select follower_id,  created_at from public.pawings
    union all select user_id,      created_at from public.location_verifications
    union all select user_id,      created_at from public.photo_verifications
  ),
  act_kst as (
    select distinct user_id, (ts at time zone tz)::date as d
    from act
    where user_id is not null and ts >= now() - interval '14 days'
  ),
  days as (
    select generate_series(today_kst - 13, today_kst, interval '1 day')::date as d
  ),
  dau_series as (
    select d.d, count(a.user_id) as c
    from days d
    left join act_kst a on a.d = d.d
    group by d.d
    order by d.d
  )
  select json_build_object(
    'unit_cost', json_build_object('sms_krw', c_sms_krw, 'ai_krw', c_ai_krw),
    'ai', json_build_object(
      'total',      (select count(*) from pv),
      'pass',       (select count(*) from pv where result = 'pass'),
      'fail',       (select count(*) from pv where result = 'fail'),
      'today',      (select count(*) from pv where (created_at at time zone tz)::date = today_kst),
      'd7',         (select count(*) from pv where created_at >= now() - interval '7 days'),
      'd30',        (select count(*) from pv where created_at >= now() - interval '30 days'),
      'cost_all',   (select count(*) from pv) * c_ai_krw,
      'cost_today', (select count(*) from pv where (created_at at time zone tz)::date = today_kst) * c_ai_krw,
      'cost_d7',    (select count(*) from pv where created_at >= now() - interval '7 days') * c_ai_krw,
      'cost_d30',   (select count(*) from pv where created_at >= now() - interval '30 days') * c_ai_krw
    ),
    'sms', json_build_object(
      'total',      (select count(*) from ph),
      'today',      (select count(*) from ph where (created_at at time zone tz)::date = today_kst),
      'd7',         (select count(*) from ph where created_at >= now() - interval '7 days'),
      'd30',        (select count(*) from ph where created_at >= now() - interval '30 days'),
      'cost_all',   (select count(*) from ph) * c_sms_krw,
      'cost_today', (select count(*) from ph where (created_at at time zone tz)::date = today_kst) * c_sms_krw,
      'cost_d7',    (select count(*) from ph where created_at >= now() - interval '7 days') * c_sms_krw,
      'cost_d30',   (select count(*) from ph where created_at >= now() - interval '30 days') * c_sms_krw
    ),
    'dau', json_build_object(
      'today',  (select c from dau_series where d = today_kst),
      'series', (select json_agg(json_build_object('d', to_char(d, 'MM-DD'), 'c', c)) from dau_series)
    )
  ) into v;
  return v;
end;
$$;
REVOKE ALL ON FUNCTION public.admin_ops_metrics() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_ops_metrics() TO authenticated;
GRANT ALL ON FUNCTION public.admin_ops_metrics() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_review_business_license(p_license uuid, p_status text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_row app.business_licenses%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_label text;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  select * into v_row from app.business_licenses where id = p_license;
  if not found then
    raise exception 'license_not_found' using errcode = 'P0001';
  end if;
  if v_row.status = p_status then
    raise exception 'no_change' using errcode = 'P0001';
  end if;
  if p_status = 'approved' and not exists (
    select 1 from public.business_profiles b
    where b.user_id = v_row.user_id and b.status = 'approved'
  ) then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;

  v_label := case v_row.license_type
    when 'grooming' then '동물미용업' when 'boarding' then '동물위탁관리업'
    when 'sales' then '동물판매업' when 'production' then '동물생산업'
    when 'exhibition' then '동물전시업' when 'transport' then '동물운송업'
  end;

  if p_status = 'rejected' then
    if v_reason is null then
      raise exception 'reason_required' using errcode = 'P0001';
    end if;
    update app.business_licenses set
      status = 'rejected', reject_reason = v_reason,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where id = p_license;

    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_row.document_path, 'license_rejected', now() + interval '6 months');

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_row.user_id, 'business_rejected', true,
            v_label || ' 인증이 반려되었어요',
            '사유: ' || v_reason || E'\n업체 관리에서 보완 후 다시 신청할 수 있어요.');
  else
    update app.business_licenses set
      status = 'approved', reject_reason = null,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where id = p_license;

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_row.user_id, 'business_approved', true,
            v_label || ' 인증이 완료되었어요',
            v_label || ' 인증이 승인되었어요. 해당 업종 기능이 열렸어요.');
  end if;

  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'review_business_license', 'user', v_row.user_id,
          jsonb_build_object('license_id', p_license, 'type', v_row.license_type,
                             'from', v_row.status, 'to', p_status, 'reason', v_reason));
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_business_status(p_user uuid, p_status text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_row public.business_profiles%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_override boolean;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;

  select * into v_row from public.business_profiles where user_id = p_user;
  if not found then
    raise exception 'application_not_found' using errcode = 'P0001';
  end if;
  if v_row.status = p_status then
    raise exception 'no_change' using errcode = 'P0001';
  end if;

  if p_status = 'rejected' then
    if v_reason is null then
      raise exception 'reason_required' using errcode = 'P0001';
    end if;

    update public.business_profiles set
      status = 'rejected', rejected_reason = v_reason,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where user_id = p_user;

    update public.users set active_mode = 'personal'
     where id = p_user and active_mode = 'business';

    insert into app.business_doc_purge_queue (path, reason, purge_after)
    select p, 'rejected', now() + interval '6 months'
      from unnest(array_remove(array[v_row.license_image_path, v_row.extra_doc_path], null)) p;

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (p_user, 'business_rejected', true, '업체 인증이 반려되었어요',
            '사유: ' || v_reason || E'\n내정보 수정에서 보완 후 다시 신청할 수 있어요.');

    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(), 'set_business_status', 'user', p_user,
            jsonb_build_object('from', v_row.status, 'to', 'rejected', 'reason', v_reason));
  else
    v_override := v_row.review_track <> 'auto';
    if v_override and v_reason is null then
      raise exception 'override_reason_required' using errcode = 'P0001';
    end if;

    update public.business_profiles set
      status = 'approved', rejected_reason = null,
      review_note = case when v_override then v_reason else review_note end,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where user_id = p_user;

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (p_user, 'business_approved', true, '업체 인증이 완료되었어요',
            '업체 인증이 승인되었어요. 내정보 수정에서 업체 모드로 전환할 수 있어요.');

    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(),
            case when v_override then 'business_override_approved' else 'set_business_status' end,
            'user', p_user,
            jsonb_build_object('from', v_row.status, 'to', 'approved',
                               'track', v_row.review_track, 'score', v_row.match_score,
                               'override', v_override, 'reason', v_reason));
  end if;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_comment_deleted(p_comment uuid, p_deleted boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists (select 1 from public.comments where id=p_comment) then
    raise exception 'comment_not_found' using errcode='P0001'; end if;
  update public.comments
     set is_deleted = p_deleted,
         deleted_at = case when p_deleted then now() else null end
   where id = p_comment;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_post_visibility(p_post uuid, p_visibility text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if p_visibility not in ('visible','hidden_by_admin','deleted_by_admin') then
    raise exception 'invalid_visibility' using errcode='P0001'; end if;
  if not exists (select 1 from public.posts where id=p_post) then
    raise exception 'post_not_found' using errcode='P0001'; end if;
  update public.posts
     set visibility_status = p_visibility,
         deleted_at = case when p_visibility like 'deleted_%' then now() else null end,
         -- 삭제 전이 시에만 좌표 파기(숨김은 복원 가능하므로 보존)
         actual_lat = case when p_visibility like 'deleted_%' then null else actual_lat end,
         actual_lng = case when p_visibility like 'deleted_%' then null else actual_lng end
   where id = p_post;
end;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_report_status(p_report uuid, p_status text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('submitted','reviewing','resolved','dismissed') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.reports where id = p_report) then
    raise exception 'report_not_found' using errcode = 'P0001';
  end if;

  update public.reports
     set status = p_status,
         reviewed_by = app.uid(),
         reviewed_at = now()
   where id = p_report;

  insert into public.admin_logs(admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'set_report_status', 'report', p_report, jsonb_build_object('status', p_status));
end;
$$;

CREATE OR REPLACE FUNCTION public.apply_business_license(p_type text, p_license_no text, p_document_path text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid  uuid := app.uid();
  v_type app.biz_license_type;
  v_no   text := nullif(btrim(coalesce(p_license_no, '')), '');
  v_path text := nullif(btrim(coalesce(p_document_path, '')), '');
  v_old  app.business_licenses%rowtype;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.business_profiles b
                 where b.user_id = v_uid and b.status in ('pending', 'approved')) then
    raise exception 'biz_profile_required' using errcode = 'P0001';
  end if;
  begin
    v_type := p_type::app.biz_license_type;
  exception when others then
    raise exception 'invalid_type' using errcode = 'P0001';
  end;
  if v_no is null or length(v_no) < 4 or length(v_no) > 40 then
    raise exception 'invalid_license_no' using errcode = 'P0001';
  end if;
  if v_path is null or position(v_uid::text || '/' in v_path) <> 1 then
    raise exception 'invalid_document_path' using errcode = 'P0001';
  end if;

  select * into v_old from app.business_licenses
   where user_id = v_uid and license_type = v_type;
  if found and v_old.status = 'approved' then
    raise exception 'already_approved' using errcode = 'P0001';
  end if;

  delete from app.business_doc_purge_queue where path = v_path;
  if found and v_old.document_path <> v_path then
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_old.document_path, 'replaced', now() + interval '1 month');
  end if;

  insert into app.business_licenses (user_id, license_type, license_no, document_path)
  values (v_uid, v_type, v_no, v_path)
  on conflict (user_id, license_type) do update
    set license_no = excluded.license_no,
        document_path = excluded.document_path,
        status = 'pending', reject_reason = null,
        reviewed_by = null, reviewed_at = null, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

CREATE OR REPLACE FUNCTION public.apply_business_profile(p_user uuid, p_b_no text, p_category text, p_business_name text, p_storefront_name text, p_prev_name text, p_address_road text, p_address_jibun text, p_region_code text, p_phone text, p_rep_name text, p_email text, p_license_path text, p_extra_doc_path text, p_nts_status_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_w_phone int;  v_on_phone boolean;
  v_w_name_high int; v_on_name_high boolean; v_sim_high real;
  v_w_name_mid int;  v_on_name_mid boolean;  v_sim_mid real;
  v_w_region int; v_on_region boolean;
  v_w_addr int;   v_on_addr boolean;   v_sim_addr real;
  v_w_cat int;    v_on_cat boolean;
  v_thr_auto int; v_thr_review int; v_auto_on boolean;
  v_names text[];
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_region5 text := left(regexp_replace(coalesce(p_region_code, ''), '\D', '', 'g'), 5);
  v_naddr text := app.norm_biz_text(p_address_jibun);
  v_biz_key text; v_score int; v_name_sim real; v_phone_ok boolean; v_any_open boolean;
  v_cats text[]; v_region_ok boolean; v_addr_sim real; v_rep_id uuid;
  v_tie_cnt int; v_grp_cnt int; v_cat_ok boolean;
  v_track text; v_status text; v_auto_approved boolean;
  v_detail jsonb;
  v_old_status text; v_old_license text; v_old_extra text;
  v_constraint text;
begin
  if p_user is null then raise exception 'invalid_user' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.users u where u.id = p_user and u.status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;
  if coalesce(p_b_no, '') !~ '^\d{10}$' then
    raise exception 'invalid_business_no' using errcode = 'P0001';
  end if;
  if p_category not in ('pet_sales','pet_hotel','animal_hospital','grooming','other') then
    raise exception 'invalid_category' using errcode = 'P0001';
  end if;
  if nullif(btrim(coalesce(p_business_name,'')), '') is null
     or nullif(btrim(coalesce(p_address_road,'')), '') is null
     or nullif(btrim(coalesce(p_email,'')), '') is null
     or nullif(btrim(coalesce(p_license_path,'')), '') is null then
    raise exception 'missing_fields' using errcode = 'P0001';
  end if;
  if coalesce(p_nts_status_code, '') <> '01' then
    raise exception 'nts_not_active' using errcode = 'P0001';
  end if;

  select bp.status, bp.license_image_path, bp.extra_doc_path
    into v_old_status, v_old_license, v_old_extra
    from public.business_profiles bp where bp.user_id = p_user;
  if v_old_status = 'pending' then raise exception 'already_pending' using errcode = 'P0001'; end if;
  if v_old_status = 'approved' then raise exception 'already_approved' using errcode = 'P0001'; end if;

  select
    coalesce(max(weight)      filter (where rule_key = 'phone_exact'), 35),
    coalesce(bool_or(enabled) filter (where rule_key = 'phone_exact'), true),
    coalesce(max(weight)      filter (where rule_key = 'name_high'), 30),
    coalesce(bool_or(enabled) filter (where rule_key = 'name_high'), true),
    coalesce(max((params->>'sim')::real) filter (where rule_key = 'name_high'), 0.85),
    coalesce(max(weight)      filter (where rule_key = 'name_mid'), 20),
    coalesce(bool_or(enabled) filter (where rule_key = 'name_mid'), true),
    coalesce(max((params->>'sim')::real) filter (where rule_key = 'name_mid'), 0.60),
    coalesce(max(weight)      filter (where rule_key = 'addr_region'), 10),
    coalesce(bool_or(enabled) filter (where rule_key = 'addr_region'), true),
    coalesce(max(weight)      filter (where rule_key = 'addr_sim'), 10),
    coalesce(bool_or(enabled) filter (where rule_key = 'addr_sim'), false),
    coalesce(max((params->>'sim')::real) filter (where rule_key = 'addr_sim'), 0.70),
    coalesce(max(weight)      filter (where rule_key = 'category_match'), 15),
    coalesce(bool_or(enabled) filter (where rule_key = 'category_match'), true),
    coalesce(max(weight)      filter (where rule_key = 'threshold_auto'), 80),
    coalesce(max(weight)      filter (where rule_key = 'threshold_review'), 50),
    coalesce(bool_or(enabled) filter (where rule_key = 'auto_approve_enabled'), false)
  into v_w_phone, v_on_phone,
       v_w_name_high, v_on_name_high, v_sim_high,
       v_w_name_mid, v_on_name_mid, v_sim_mid,
       v_w_region, v_on_region,
       v_w_addr, v_on_addr, v_sim_addr,
       v_w_cat, v_on_cat,
       v_thr_auto, v_thr_review, v_auto_on
  from public.business_match_rules;

  v_names := array(
    select distinct n from unnest(array[
      app.norm_biz_text(p_business_name),
      app.norm_biz_text(p_storefront_name),
      app.norm_biz_text(p_prev_name)
    ]) n where n is not null and n <> ''
  );

  -- 후보 검색 → 물리 업소(biz_key) 그룹핑 → 점수 (0025 §4.3~4.4).
  -- pet_cafe 제외. is_open 필터 없음 — 폐업 표시는 데이터 지연일 수 있어 후보에 포함하되
  -- 자동승인만 막는다(예외표 Case 7).
  if p_category <> 'other' then
    with cand as (
      select f.id, f.category::text as category, f.is_open, f.region_code,
             app.norm_biz_text(f.name::text) as nname,
             app.norm_biz_text(coalesce(f.address, '')) as naddr,
             regexp_replace(coalesce(f.phone, ''), '\D', '', 'g') as nphone,
             (select max(extensions.similarity(app.norm_biz_text(f.name::text), n))
                from unnest(v_names) n) as name_sim
        from public.facilities f
       where f.category in ('pet_sales','pet_hotel','animal_hospital','grooming')
    ),
    hit as (
      select * from cand
       where coalesce(name_sim, 0) >= v_sim_mid
          or (v_phone <> '' and nphone = v_phone)
    ),
    grp as (
      select h.nname || '|' || h.naddr as biz_key,
             max(h.name_sim) as name_sim,
             bool_or(v_phone <> '' and h.nphone = v_phone) as phone_ok,
             bool_or(h.is_open) as any_open,
             array_agg(distinct h.category) as cats,
             bool_or(v_region5 <> '' and h.region_code is not null
                     and left(h.region_code, 5) = v_region5) as region_ok,
             max(extensions.similarity(h.naddr, v_naddr)) as addr_sim,
             (array_agg(h.id order by (h.category = p_category)::int desc, h.id))[1] as rep_id
        from hit h
       group by h.nname || '|' || h.naddr
    ),
    scored as (
      select g.*,
             ( case when v_on_phone and g.phone_ok then v_w_phone else 0 end
             + case when v_on_name_high and g.name_sim >= v_sim_high then v_w_name_high
                    when v_on_name_mid  and g.name_sim >= v_sim_mid  then v_w_name_mid
                    else 0 end
             + case when v_on_region and g.region_ok then v_w_region else 0 end
             + case when v_on_addr and coalesce(g.addr_sim, 0) >= v_sim_addr then v_w_addr else 0 end
             + case when v_on_cat and p_category = any(g.cats) then v_w_cat else 0 end
             )::int as score
        from grp g
    )
    select s.biz_key, s.score, s.name_sim, s.phone_ok, s.any_open, s.cats,
           s.region_ok, s.addr_sim, s.rep_id,
           (select count(*) from scored s2 where s2.score = s.score),
           (select count(*) from scored)
      into v_biz_key, v_score, v_name_sim, v_phone_ok, v_any_open, v_cats,
           v_region_ok, v_addr_sim, v_rep_id, v_tie_cnt, v_grp_cnt
      from scored s
     order by s.score desc, s.biz_key
     limit 1;
  end if;

  v_cat_ok := v_cats is not null and p_category = any(v_cats);

  -- 트랙 판정 — 필수 신호(전화·업종)는 합계와 별개의 AND (0025 §4.4, 설계 원칙 2)
  if p_category = 'other' or v_biz_key is null or v_score < v_thr_review then
    v_track := 'new_business';
  elsif v_phone_ok and v_cat_ok and v_tie_cnt = 1 and v_any_open and v_score >= v_thr_auto then
    v_track := 'auto';
  else
    v_track := 'review';
  end if;

  -- 신규개업 트랙: 추가 서류를 INSERT '전에' 요구 (0025 §4.5)
  if v_track = 'new_business' and nullif(btrim(coalesce(p_extra_doc_path, '')), '') is null then
    raise exception 'extra_doc_required' using errcode = 'P0001';
  end if;

  v_auto_approved := v_track = 'auto' and v_auto_on;
  v_status := case when v_auto_approved then 'approved' else 'pending' end;

  -- 저확신(new_business)은 업소 키를 점유하지 않는다
  if v_track = 'new_business' then
    v_biz_key := null; v_rep_id := null;
  end if;

  v_detail := jsonb_build_object(
    'name_sim',    round(coalesce(v_name_sim, 0)::numeric, 3),
    'phone_ok',    coalesce(v_phone_ok, false),
    'region_ok',   coalesce(v_region_ok, false),
    'addr_sim',    round(coalesce(v_addr_sim, 0)::numeric, 3),
    'category_ok', coalesce(v_cat_ok, false),
    'categories',  to_jsonb(coalesce(v_cats, '{}'::text[])),
    'tie_count',   coalesce(v_tie_cnt, 0),
    'group_count', coalesce(v_grp_cnt, 0),
    'any_open',    coalesce(v_any_open, false),
    'weights', jsonb_build_object(
      'phone', v_w_phone, 'name_high', v_w_name_high, 'name_mid', v_w_name_mid,
      'addr_region', v_w_region, 'addr_sim', v_w_addr, 'category', v_w_cat,
      'thr_auto', v_thr_auto, 'thr_review', v_thr_review),
    'auto_switch', v_auto_on
  );

  begin
    insert into public.business_profiles as bp (
      user_id, business_reg_no, declared_category, business_name, storefront_name,
      prev_business_name, business_address, business_address_jibun, business_region_code,
      business_phone, representative_name, contact_email, license_image_path, extra_doc_path,
      nts_status_code, nts_checked_at, matched_facility_id, matched_biz_key,
      match_score, match_detail, review_track, auto_approved, status
    ) values (
      p_user, p_b_no, p_category, btrim(p_business_name), nullif(btrim(coalesce(p_storefront_name,'')), ''),
      nullif(btrim(coalesce(p_prev_name,'')), ''), btrim(p_address_road),
      nullif(btrim(coalesce(p_address_jibun,'')), ''), nullif(v_region5, ''),
      nullif(v_phone, ''), nullif(btrim(coalesce(p_rep_name,'')), ''), btrim(p_email),
      p_license_path, nullif(btrim(coalesce(p_extra_doc_path,'')), ''),
      p_nts_status_code, now(), v_rep_id, v_biz_key,
      v_score, v_detail, v_track, v_auto_approved, v_status
    )
    on conflict (user_id) do update set
      business_reg_no = excluded.business_reg_no,
      declared_category = excluded.declared_category,
      business_name = excluded.business_name,
      storefront_name = excluded.storefront_name,
      prev_business_name = excluded.prev_business_name,
      business_address = excluded.business_address,
      business_address_jibun = excluded.business_address_jibun,
      business_region_code = excluded.business_region_code,
      business_phone = excluded.business_phone,
      representative_name = excluded.representative_name,
      contact_email = excluded.contact_email,
      license_image_path = excluded.license_image_path,
      extra_doc_path = excluded.extra_doc_path,
      nts_status_code = excluded.nts_status_code,
      nts_checked_at = excluded.nts_checked_at,
      matched_facility_id = excluded.matched_facility_id,
      matched_biz_key = excluded.matched_biz_key,
      match_score = excluded.match_score,
      match_detail = excluded.match_detail,
      review_track = excluded.review_track,
      auto_approved = excluded.auto_approved,
      status = excluded.status,
      rejected_reason = null, reviewed_by = null, reviewed_at = null, review_note = null,
      updated_at = now();
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'business_profiles_regno_active_uq' then
      raise exception 'business_no_taken' using errcode = 'P0001';
    elsif v_constraint = 'business_profiles_bizkey_active_uq' then
      raise exception 'facility_taken' using errcode = 'P0001';
    else
      raise;
    end if;
  end;

  -- 재신청이 반려 때 큐에 올라간 같은 파일을 재사용하면 파기 취소
  delete from app.business_doc_purge_queue q
   where q.purged_at is null
     and q.path in (p_license_path, coalesce(p_extra_doc_path, ''));

  -- 교체된 옛 서류는 30일 후 파기 (0025 §3.3)
  if v_old_license is not null and v_old_license <> p_license_path then
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_old_license, 'superseded', now() + interval '30 days');
  end if;
  if v_old_extra is not null and v_old_extra is distinct from p_extra_doc_path then
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_old_extra, 'superseded', now() + interval '30 days');
  end if;

  -- 자동승인: 알림 + 감사로그(admin_id null = 시스템, 0025 §4.6)
  if v_auto_approved then
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (p_user, 'business_approved', true, '업체 인증이 완료되었어요',
            '입력하신 정보가 확인되어 업체 인증이 자동 승인되었어요. 내정보 수정에서 업체 모드로 전환할 수 있어요.');
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (null, 'business_auto_approved', 'user', p_user,
            v_detail || jsonb_build_object('score', v_score));
  end if;

  return jsonb_build_object('track', v_track, 'status', v_status, 'score', v_score);
end;
$_$;

CREATE OR REPLACE FUNCTION public.business_doc_purge_take(p_limit integer DEFAULT 200) RETURNS TABLE(id bigint, path text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  delete from app.business_doc_purge_queue q
   where q.purged_at is null
     and exists (select 1 from public.business_profiles bp
                  where bp.status in ('pending','approved')
                    and (bp.license_image_path = q.path or bp.extra_doc_path = q.path));
  return query
  select q.id, q.path
    from app.business_doc_purge_queue q
   where q.purged_at is null and q.purge_after <= now()
   order by q.id
   limit greatest(1, least(coalesce(p_limit, 200), 500));
end;
$$;

CREATE OR REPLACE FUNCTION public.claim_care_reports() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := app.uid();
  v_hmac bytea;
  v_cnt integer := 0;
  r record;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  select app.phone_hmac(u.phone) into v_hmac from public.users u where u.id = v_uid;
  if v_hmac is null then return 0; end if;

  for r in
    update app.care_reports cr
       set claimed_by = v_uid, claimed_at = now(), recipient_phone_hmac = null
     where cr.recipient_phone_hmac = v_hmac
       and cr.claimed_by is null
       and cr.business_id <> v_uid
    returning cr.id, cr.pet_label
  loop
    v_cnt := v_cnt + 1;
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_uid, 'system_notice', true,
            r.pet_label || ' 케어 기록이 도착했어요',
            '업체가 보내준 ' || r.pet_label || ' 사진을 앱에서 확인해 보세요.');
    insert into app.funnel_events (event, token, user_id)
    select 'claim', l.token, v_uid
      from app.share_links l
     where l.kind = 'care_report' and l.ref_id = r.id;
  end loop;

  for r in
    update app.care_threads t
       set claimed_by = v_uid, claimed_at = now(), recipient_phone_hmac = null
     where t.recipient_phone_hmac = v_hmac
       and t.claimed_by is null
       and t.business_id <> v_uid
    returning t.id, t.pet_label
  loop
    v_cnt := v_cnt + 1;
    update app.care_reports set claimed_by = v_uid, claimed_at = now()
     where thread_id = r.id and claimed_by is null;
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_uid, 'system_notice', true,
            r.pet_label || ' 알림장이 연결됐어요',
            '이제 ' || r.pet_label || ' 돌봄 기록이 도착할 때마다 알려드려요.');
    insert into app.funnel_events (event, user_id, props)
    values ('claim', v_uid, jsonb_build_object('thread_id', r.id));
  end loop;

  return v_cnt;
end;
$$;
REVOKE ALL ON FUNCTION public.claim_care_reports() FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_care_reports() TO authenticated;
GRANT ALL ON FUNCTION public.claim_care_reports() TO service_role;

CREATE OR REPLACE FUNCTION public.create_boarding_report(p_thread uuid, p_photos jsonb DEFAULT '[]'::jsonb, p_body jsonb DEFAULT '{}'::jsonb, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := app.uid();
  v_thread app.care_threads%rowtype;
  v_report uuid;
  v_token varchar(32);
  v_exp timestamptz;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not app.has_license('boarding') then
    raise exception 'license_required' using errcode = 'P0001';
  end if;
  select * into v_thread from app.care_threads
   where id = p_thread and business_id = v_uid;
  if not found then
    raise exception 'thread_not_found' using errcode = 'P0001';
  end if;
  if jsonb_typeof(coalesce(p_photos, '[]'::jsonb)) is distinct from 'array'
     or jsonb_array_length(coalesce(p_photos, '[]'::jsonb)) > 4 then
    raise exception 'invalid_photos' using errcode = 'P0001';
  end if;
  if jsonb_typeof(coalesce(p_body, '{}'::jsonb)) is distinct from 'object' then
    raise exception 'invalid_body' using errcode = 'P0001';
  end if;
  if jsonb_array_length(coalesce(p_photos, '[]'::jsonb)) = 0
     and coalesce(p_body, '{}'::jsonb) = '{}'::jsonb
     and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'empty_report' using errcode = 'P0001';
  end if;

  insert into app.care_reports
    (business_id, kind, pet_label, photos, body, note, thread_id, claimed_by, claimed_at)
  values
    (v_uid, 'boarding', v_thread.pet_label, coalesce(p_photos, '[]'::jsonb),
     coalesce(p_body, '{}'::jsonb), nullif(btrim(coalesce(p_note, '')), ''),
     p_thread,
     v_thread.claimed_by, case when v_thread.claimed_by is null then null else now() end)
  returning id into v_report;

  update app.care_threads set last_report_at = now() where id = p_thread;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp := now() + interval '30 days';
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'care_report', v_report, v_uid, v_exp);

  insert into app.funnel_events (event, token, user_id)
  values ('report_issued', v_token, v_uid);

  if v_thread.claimed_by is not null then
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_thread.claimed_by, 'system_notice', true,
            v_thread.pet_label || ' 돌봄 기록이 도착했어요',
            '오늘의 ' || v_thread.pet_label || ' 소식을 앱에서 확인해 보세요.');
  end if;

  return jsonb_build_object('report_id', v_report, 'token', v_token, 'expires_at', v_exp);
end;
$$;

CREATE OR REPLACE FUNCTION public.create_care_report(p_pet_label text, p_photos jsonb, p_note text DEFAULT NULL::text, p_recipient_phone text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := app.uid();
  v_label text := nullif(btrim(coalesce(p_pet_label, '')), '');
  v_hmac bytea;
  v_report uuid;
  v_token varchar(32);
  v_exp timestamptz;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not app.has_license('grooming') then
    raise exception 'license_required' using errcode = 'P0001';
  end if;
  if v_label is null or length(v_label) > 50 then
    raise exception 'invalid_pet_label' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_photos) is distinct from 'array'
     or jsonb_array_length(p_photos) not between 1 and 4 then
    raise exception 'invalid_photos' using errcode = 'P0001';
  end if;
  if p_recipient_phone is not null and btrim(p_recipient_phone) <> '' then
    v_hmac := app.phone_hmac(p_recipient_phone);
    if v_hmac is null then
      raise exception 'invalid_phone' using errcode = 'P0001';
    end if;
  end if;

  insert into app.care_reports
    (business_id, kind, pet_label, photos, note,
     recipient_phone_hmac, recipient_key_version)
  values
    (v_uid, 'grooming', v_label, p_photos, nullif(btrim(coalesce(p_note, '')), ''),
     v_hmac, (select key_version from app.care_config))
  returning id into v_report;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp := now() + interval '30 days';
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'care_report', v_report, v_uid, v_exp);

  insert into app.funnel_events (event, token, user_id)
  values ('report_issued', v_token, v_uid);

  return jsonb_build_object('report_id', v_report, 'token', v_token, 'expires_at', v_exp);
end;
$$;

CREATE OR REPLACE FUNCTION public.create_post_verified(p_category character varying, p_title character varying, p_content text, p_scheduled_at timestamp with time zone, p_pet_ids uuid[], p_image_url text, p_image_mime character varying, p_image_size integer, p_photo_token uuid DEFAULT NULL::uuid, p_actual_lat double precision DEFAULT NULL::double precision, p_actual_lng double precision DEFAULT NULL::double precision, p_region_code character varying DEFAULT NULL::character varying, p_image_thumb_url text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid  uuid := app.uid();
  v_post uuid;
  v_pv   public.photo_verifications%rowtype;
  v_exempt boolean := false;
  v_user record;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

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
    v_exempt := p_pet_ids is not null
            and array_length(p_pet_ids, 1) >= 1
            and not exists (
                  select 1 from public.pets
                   where id = any(p_pet_ids)
                     and app.needs_photo_gate(verify_post_count));

    if v_exempt then
      perform set_config('app.photo_trusted', 'true', true);
    else
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

CREATE OR REPLACE FUNCTION public.enroll_pet_identity(p_pet uuid, p_species character varying, p_paths text[], p_urls text[], p_breed character varying DEFAULT NULL::character varying, p_colors text[] DEFAULT NULL::text[], p_info_match jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  delete from public.pet_identity_frames where pet_id = p_pet;
  insert into public.pet_identity_frames (pet_id, frame_index, image_url, image_path)
    select p_pet, i - 1, p_urls[i], p_paths[i]
      from generate_subscripts(p_urls, 1) as i;
  update public.pets
     set identity_verified = true,
         identity_verified_at = now(),
         ai_species = p_species,
         ai_breed = p_breed,
         ai_colors = p_colors,
         info_match = p_info_match,
         updated_at = now()
   where id = p_pet;
end;
$$;

CREATE OR REPLACE FUNCTION public.facility_review_by_id(p_review uuid) RETURNS TABLE(id uuid, user_id uuid, author_nickname text, rating smallint, content text, photo_urls text[], created_at timestamp with time zone, is_mine boolean, visit_no integer, has_incentive boolean, videos jsonb)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select r.id, r.user_id,
         case when au.status = 'lite' then app.mask_phone(au.phone)
              else pr.nickname end,
         r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid_lite()) as is_mine, r.visit_no, r.has_incentive, r.videos
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
    left join public.users au on au.id = r.user_id
   where r.id = p_review;
$$;

CREATE OR REPLACE FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, user_id uuid, author_nickname text, rating smallint, content text, photo_urls text[], created_at timestamp with time zone, is_mine boolean, visit_no integer, has_incentive boolean, videos jsonb)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select r.id, r.user_id,
         case when au.status = 'lite' then app.mask_phone(au.phone)
              else pr.nickname end,
         r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid_lite()) as is_mine, r.visit_no, r.has_incentive, r.videos
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
    left join public.users au on au.id = r.user_id
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$$;

CREATE OR REPLACE FUNCTION public.login_issue_refresh(p_user uuid, p_token_hash text, p_user_agent text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_had_other boolean; v_tv integer;
begin
  select exists(
    select 1 from app.refresh_tokens
    where user_id = p_user and revoked_at is null and expires_at > now()
  ) into v_had_other;

  insert into app.refresh_tokens(
    user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent
  ) values (
    p_user, p_token_hash, gen_random_uuid(),
    now() + interval '30 days', now() + interval '90 days', p_user_agent
  );

  if v_had_other then
    insert into public.notifications(user_id, notification_type, is_system, title, body)
    values (p_user, 'security_login', true,
            '새 기기에서 로그인되었어요',
            '본인이 아니라면 비밀번호를 변경해주세요.');
  end if;

  select token_version into v_tv from public.users u where u.id = p_user;
  return coalesce(v_tv, 0);
end $$;

CREATE OR REPLACE FUNCTION public.record_location_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_result text, p_region_code character varying, p_address character varying, p_fail_reason character varying, p_fail_limit integer DEFAULT 5, p_block_minutes integer DEFAULT 60) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  insert into public.location_verifications
    (user_id, verified_lat, verified_lng, verified_radius_meters, result, fail_reason)
  values
    (p_user, p_lat, p_lng, greatest(coalesce(p_accuracy, 0), 0), p_result, p_fail_reason);

  if p_result = 'success' then
    update public.users
       set latitude = p_lat,
           longitude = p_lng,
           region_code = p_region_code,
           address = p_address,
           is_location_verified = true,
           last_verified_at = now(),
           location_verify_fail_count = 0,
           location_verify_blocked_until = null,
           updated_at = now()
     where id = p_user;
  else
    update public.users
       set location_verify_fail_count = location_verify_fail_count + 1,
           location_verify_blocked_until = case
             when location_verify_fail_count + 1 >= p_fail_limit
               then now() + make_interval(mins => p_block_minutes)
             else location_verify_blocked_until end,
           updated_at = now()
     where id = p_user;
  end if;
end;
$$;

CREATE OR REPLACE FUNCTION public.share_view_load(p_token character varying) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
        'id', f.id,
        'photo_url', bp.photo_url,
        'photo_align_y', coalesce(bp.photo_align_y, 0),
        'business_hours', bp.business_hours,
        'owner_user_id', bp.user_id,
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
      select true as verified, b.user_id, b.photo_url, b.photo_align_y, b.business_hours
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

  if v_link.kind = 'post' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'post', jsonb_build_object(
        'id', p.id,
        'category', p.category, 'title', p.title, 'content', p.content,
        'image_url', p.image_url, 'image_mime', p.image_mime_type,
        'image_thumb_url', p.image_thumbnail_url,
        'created_at', p.created_at,
        'author_name', case
          when p.category = 'news'
            then coalesce(b.storefront_name, b.business_name, pr.nickname)
          else pr.nickname end))
    into v_out
    from public.posts p
    left join public.public_profiles pr on pr.id = p.user_id
    left join public.business_profiles b
      on p.category = 'news' and b.user_id = p.user_id
    where p.id = v_link.ref_id and p.visibility_status = 'visible';
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$$;

CREATE OR REPLACE FUNCTION public.signup_user(p_username text, p_password_hash text, p_nickname text, p_user_type text, p_phone text, p_marketing boolean DEFAULT false) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_id     uuid;
  v_status text;
begin
  -- 1) 전화 인증 완료 확인 (signup 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'signup'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  -- 2) 중복 사전 검사 (유니크 인덱스가 최종 방어선, 여기선 친절한 에러코드용)
  if exists (select 1 from public.users where lower(username) = lower(p_username)) then
    raise exception 'username_taken' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.users where lower(nickname) = lower(p_nickname)) then
    raise exception 'nickname_taken' using errcode = 'P0001';
  end if;

  -- 3) 같은 번호가 이미 있으면 — lite 면 승격, 그 외엔 기존대로 거부.
  select id, status into v_id, v_status
    from public.users where phone = p_phone;

  if found then
    if v_status <> 'lite' then
      raise exception 'phone_taken' using errcode = 'P0001';
    end if;
    update public.users set
      username            = p_username,
      password_hash       = p_password_hash,
      nickname            = p_nickname,
      user_type           = p_user_type,
      status              = 'active',
      terms_agreed_at     = now(),
      marketing_opt_in    = coalesce(p_marketing, false),
      marketing_opt_in_at = case when coalesce(p_marketing, false) then now() else null end,
      updated_at          = now()
    where id = v_id;
    return v_id;
  end if;

  -- 4) 신규 INSERT (해시는 엣지에서 argon2id 로 생성, 필수 약관 동의 시각 기록)
  insert into public.users (
    username, password_hash, nickname, user_type, phone, phone_verified,
    terms_agreed_at, marketing_opt_in, marketing_opt_in_at
  ) values (
    p_username,
    p_password_hash,
    p_nickname,
    p_user_type,
    p_phone,
    true,
    now(),
    coalesce(p_marketing, false),
    case when coalesce(p_marketing, false) then now() else null end
  )
  returning id into v_id;

  return v_id;
end;
$$;

CREATE OR REPLACE FUNCTION public.start_direct_chat(p_other uuid, p_context text DEFAULT 'personal'::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
  if p_context = 'business' and not exists (
    select 1 from public.business_profiles bp
     where bp.user_id = p_other and bp.status = 'approved'
  ) then
    raise exception 'not_a_business' using errcode = 'P0001';
  end if;

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
$$;

CREATE OR REPLACE FUNCTION public.withdraw_account() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_me uuid := app.uid();
  v_tag text;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  v_tag := substr(replace(v_me::text, '-', ''), 1, 10);

  insert into app.withdrawn_users (user_id, username, phone)
  select u.id, u.username, u.phone from public.users u where u.id = v_me
  on conflict (user_id) do nothing;

  update public.users set
    username = 'del_' || v_tag,
    nickname = '탈퇴회원' || v_tag,
    password_hash = '!',
    phone = null,
    phone_verified = false,
    profile_image_url = null,
    profile_image_thumbnail_url = null,
    profile_image_mime_type = null,
    profile_image_file_size = null,
    address = null,
    latitude = null,
    longitude = null,
    is_location_verified = false,
    region_code = null,
    activity_radius_m = null,
    push_enabled = false,
    marketing_opt_in = false,
    unread_notification_count = 0,
    unread_chat_count = 0,
    active_mode = 'personal',
    status = 'deleted',
    deleted_at = now(),
    token_version = token_version + 1
  where id = v_me and status = 'active';
  if not found then
    raise exception 'not_active_account' using errcode = 'P0001';
  end if;

  delete from public.location_verifications where user_id = v_me;
  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where user_id = v_me
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);
  update public.posts
     set actual_lat = null, actual_lng = null
   where user_id = v_me
     and (actual_lat is not null or actual_lng is not null);

  -- 업체 프로필: 번호·업소 키 반납(부분 유니크 해제) + 서류 30일 파기 큐 (0025 §2.2·§3.3)
  insert into app.business_doc_purge_queue (path, reason, purge_after)
  select p, 'withdraw', now() + interval '30 days'
    from public.business_profiles bp,
         unnest(array_remove(array[bp.license_image_path, bp.extra_doc_path], null)) p
   where bp.user_id = v_me;
  update public.business_profiles
     set status = 'rejected',
         rejected_reason = coalesce(rejected_reason, 'withdrawn'),
         updated_at = now()
   where user_id = v_me and status <> 'rejected';

  delete from app.refresh_tokens where user_id = v_me;
  delete from public.device_tokens where user_id = v_me;
  delete from public.notifications where user_id = v_me;
  delete from public.notification_preferences where user_id = v_me;

  delete from public.pawings where follower_id = v_me or following_id = v_me;

  update public.pets set pet_status = 'deleted', updated_at = now()
   where primary_guardian_id = v_me and pet_status <> 'deleted';
  delete from public.pet_guardians where user_id = v_me;

  update public.chat_room_members set left_at = now(), updated_at = now()
   where user_id = v_me and left_at is null;
end $$;


SET default_tablespace = '';

SET default_table_access_method = heap;
REVOKE ALL ON FUNCTION public.withdraw_account() FROM PUBLIC;
GRANT ALL ON FUNCTION public.withdraw_account() TO authenticated;
GRANT ALL ON FUNCTION public.withdraw_account() TO service_role;

-- ── 권한만 다른 함수 ─────────────────────────────────────────────────────
revoke all on function public.admin_room_messages(p_room uuid, p_limit integer) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_room_messages(p_room uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_room_messages(p_room uuid, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_room_messages(p_room uuid, p_limit integer) TO service_role;

revoke all on function public.delete_my_chat_message(p_message uuid) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_my_chat_message(p_message uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_my_chat_message(p_message uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_my_chat_message(p_message uuid) TO service_role;

revoke all on function public.facilities_search(p_query text, p_lng double precision, p_lat double precision) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) TO authenticated;
GRANT ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) TO service_role;
GRANT ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) TO anon;

revoke all on function public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) TO authenticated;
GRANT ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) TO service_role;
GRANT ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) TO anon;

revoke all on function public.facility_all_categories(p_id uuid) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.facility_all_categories(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facility_all_categories(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.facility_all_categories(p_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.facility_all_categories(p_id uuid) TO anon;

revoke all on function public.facility_review_by_id(p_review uuid) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.facility_review_by_id(p_review uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facility_review_by_id(p_review uuid) TO authenticated;
GRANT ALL ON FUNCTION public.facility_review_by_id(p_review uuid) TO service_role;
GRANT ALL ON FUNCTION public.facility_review_by_id(p_review uuid) TO anon;

revoke all on function public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) TO service_role;
GRANT ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) TO anon;

revoke all on function public.public_user_pets(p_user uuid) from public, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.public_user_pets(p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_user_pets(p_user uuid) TO authenticated;
GRANT ALL ON FUNCTION public.public_user_pets(p_user uuid) TO service_role;

-- ── 코멘트 ───────────────────────────────────────────────────────────────
COMMENT ON TABLE public.facilities IS '공공데이터 반려동물 시설(병원/미용/위탁/판매). geom=WGS84(4326). 적재시 좌표 사전변환됨 (0021).';
