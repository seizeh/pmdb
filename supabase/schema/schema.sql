--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: app; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA app;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: biz_license_type; Type: TYPE; Schema: app; Owner: -
--

CREATE TYPE app.biz_license_type AS ENUM (
    'grooming',
    'boarding',
    'sales',
    'production',
    'exhibition',
    'transport'
);


--
-- Name: facility_category; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.facility_category AS ENUM (
    'animal_hospital',
    'grooming',
    'pet_hotel',
    'pet_cafe',
    'pet_sales'
);


--
-- Name: applications_block_business_mode(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.applications_block_business_mode() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_mode text;
begin
  select u.active_mode into v_mode
    from public.users u where u.id = new.applicant_id;
  if v_mode = 'business' then
    raise exception 'business_mode_not_allowed' using errcode = 'P0001';
  end if;
  return new;
end;
$$;


--
-- Name: assert_business_actor(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.assert_business_actor() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if coalesce(
       (select u.active_mode from public.users u where u.id = app.uid()),
       'personal') <> 'business' then
    raise exception 'business_mode_required' using errcode = 'P0001';
  end if;
end;
$$;


--
-- Name: assert_personal_actor(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.assert_personal_actor() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if (select u.active_mode from public.users u where u.id = app.uid()) = 'business' then
    raise exception 'business_mode_not_allowed' using errcode = 'P0001';
  end if;
end;
$$;


--
-- Name: chat_block_left_room(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.chat_block_left_room() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if exists (
    select 1 from public.chat_room_members m
    where m.room_id = new.room_id and m.left_at is not null
  ) then
    raise exception '상대가 채팅방을 나가 메시지를 보낼 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;


--
-- Name: cleanup_auth(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.cleanup_auth() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  delete from app.refresh_tokens
   where absolute_expires_at < now()
      or (revoked_at is not null and revoked_at < now() - interval '1 day')
      or (revoked_at is null and expires_at < now() - interval '1 day');
  delete from app.rate_limits where expires_at < now();
$$;


--
-- Name: cleanup_retention(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.cleanup_retention() RETURNS void
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


--
-- Name: comments_set_authored_as(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.comments_set_authored_as() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  select u.active_mode into new.authored_as
    from public.users u where u.id = new.user_id;
  new.authored_as := coalesce(new.authored_as, 'personal');
  return new;
end;
$$;


--
-- Name: deactivate_device_token(text, text); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.deactivate_device_token(p_token text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update public.device_tokens
     set is_active     = false,
         failure_count = failure_count + 1,
         updated_at    = now()
   where token = p_token
$$;


--
-- Name: FUNCTION deactivate_device_token(p_token text, p_reason text); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.deactivate_device_token(p_token text, p_reason text) IS 'Edge Function 이 APNs InvalidToken / FCM UNREGISTERED 응답 시 호출. is_active=false 로 발송 대상에서 제외';


--
-- Name: dispatch_engagement_notifications(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.dispatch_engagement_notifications() RETURNS void
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


--
-- Name: has_license(app.biz_license_type); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.has_license(p_type app.biz_license_type) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from app.business_licenses
    where user_id = app.uid() and license_type = p_type and status = 'approved'
  );
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.users u
    where u.id = app.uid()
      and u.user_type = 'admin'
      and u.status = 'active'
  )
$$;


--
-- Name: is_pet_guardian(uuid, text); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.is_pet_guardian(p_pet uuid, p_role text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from public.pet_guardians g
    where g.pet_id = p_pet
      and g.user_id = app.uid()
      and (p_role is null or g.role = p_role)
  )
$$;


--
-- Name: is_post_manager(uuid); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.is_post_manager(p_post uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select
    exists (
      select 1 from public.posts p
       where p.id = p_post and p.user_id = app.uid()
    )
    or exists (
      select 1
        from public.post_pets pp
        join public.pet_guardians g on g.pet_id = pp.pet_id
       where pp.post_id = p_post and g.user_id = app.uid()
    )
    or app.is_admin()
$$;


--
-- Name: is_room_member(uuid); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.is_room_member(p_room uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from public.chat_room_members m
    where m.room_id = p_room and m.user_id = app.uid()
  )
$$;


--
-- Name: mark_push_failed(uuid, text, boolean, smallint); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.mark_push_failed(p_notification_id uuid, p_error text DEFAULT NULL::text, p_final boolean DEFAULT false, p_max_attempts smallint DEFAULT 3) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_current smallint;
  v_next    smallint;
begin
  select push_attempts into v_current
    from public.notifications where id = p_notification_id;
  if v_current is null then
    raise exception 'mark_push_failed: 알림(%) 을 찾을 수 없음', p_notification_id;
  end if;
  v_next := v_current + 1;

  update public.notifications
     set push_attempts = v_next,
         push_error    = p_error,
         push_status   = case
           when p_final or v_next >= p_max_attempts then 'failed'
           else 'pending'   -- 다음 webhook/폴링이 다시 가져감
         end,
         updated_at    = now()
   where id = p_notification_id;
end;
$$;


--
-- Name: FUNCTION mark_push_failed(p_notification_id uuid, p_error text, p_final boolean, p_max_attempts smallint); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.mark_push_failed(p_notification_id uuid, p_error text, p_final boolean, p_max_attempts smallint) IS 'Edge Function 이 FCM/APNs 실패 응답 시 호출. p_final=true 또는 시도횟수 임계 초과 시 영구실패(failed), 아니면 pending 유지로 재시도 큐 잔류';


--
-- Name: mark_push_sent(uuid); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.mark_push_sent(p_notification_id uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update public.notifications
     set push_status  = 'sent',
         push_sent    = true,
         push_sent_at = now(),
         updated_at   = now()
   where id = p_notification_id
$$;


--
-- Name: FUNCTION mark_push_sent(p_notification_id uuid); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.mark_push_sent(p_notification_id uuid) IS 'Edge Function 이 FCM/APNs 성공 응답 시 호출. push_status=sent + push_sent_at 갱신';


--
-- Name: mark_push_skipped(uuid, text); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.mark_push_skipped(p_notification_id uuid, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update public.notifications
     set push_status = 'skipped',
         push_error  = p_reason,
         updated_at  = now()
   where id = p_notification_id
$$;


--
-- Name: norm_biz_text(text); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.norm_biz_text(t text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path TO ''
    AS $$
  select regexp_replace(
           lower(
             regexp_replace(
               regexp_replace(coalesce(t, ''),
                 '주식회사|유한회사|유한책임회사|합자회사|합명회사|\(주\)|㈜|\(유\)|\(합\)', '', 'g'),
               '\([^)]*\)', '', 'g')
           ),
           '[^0-9a-z가-힣]', '', 'g')
$$;


--
-- Name: notif_trunc(text, integer); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.notif_trunc(p_text text, p_max integer DEFAULT 60) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case
    when p_text is null then null
    when length(p_text) > p_max then left(p_text, p_max - 1) || '…'
    else p_text
  end;
$$;


--
-- Name: on_notification_push(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.on_notification_push() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_url text; v_secret text;
begin
  if new.push_status = 'pending' and coalesce(new.is_silent, false) = false then
    select function_url, trigger_secret into v_url, v_secret from app.push_config limit 1;
    if v_url is not null then
      perform net.http_post(
        url := v_url,
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
        body := jsonb_build_object('notification_id', new.id)
      );
    end if;
  end if;
  return new;
end $$;


--
-- Name: posts_set_authored_as(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.posts_set_authored_as() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  select u.active_mode into new.authored_as
    from public.users u where u.id = new.user_id;
  new.authored_as := coalesce(new.authored_as, 'personal');

  -- 업체 모드 글은 카테고리 무관 항상 '소식' — 매칭 카테고리 사용 불가.
  -- 개인 모드 글의 news 는 거부(소식은 업체 전용 분류).
  if new.authored_as = 'business' then
    new.category := 'news';
  elsif new.category = 'news' then
    raise exception 'posts: 소식 카테고리는 업체 계정 전용이에요';
  end if;

  return new;
end;
$$;


--
-- Name: reconcile_unread_counts(uuid); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.reconcile_unread_counts(p_user_id uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_user     uuid;
  v_chat     int := 0;
  v_notif    int := 0;
  r          record;
  v_per      int;
  v_read_ts  timestamptz;
  v_read_id  uuid;
begin
  v_user := coalesce(p_user_id, app.uid());
  if v_user is null then
    raise exception 'reconcile_unread_counts: 대상 사용자가 지정되지 않았습니다';
  end if;

  -- 본인이 아닌 다른 사용자 대상 호출은 관리자/시스템(=app.uid() NULL) 한정
  if app.uid() is not null and app.uid() <> v_user and not app.is_admin() then
    raise exception 'reconcile_unread_counts: 본인 카운트만 보정할 수 있습니다';
  end if;

  -- (1) 미읽음 채팅 합계: 방별 last_read_message_id 기준 (created_at, id) 튜플 비교
  for r in
    select room_id, last_read_message_id
      from public.chat_room_members
     where user_id = v_user
  loop
    if r.last_read_message_id is null then
      select count(*) into v_per
        from public.chat_messages msg
       where msg.room_id   = r.room_id
         and msg.sender_id <> v_user
         and msg.is_deleted = false;
    else
      select created_at, id into v_read_ts, v_read_id
        from public.chat_messages
       where id = r.last_read_message_id;
      select count(*) into v_per
        from public.chat_messages msg
       where msg.room_id   = r.room_id
         and msg.sender_id <> v_user
         and msg.is_deleted = false
         and (msg.created_at, msg.id) > (v_read_ts, v_read_id);
    end if;
    v_chat := v_chat + coalesce(v_per, 0);
  end loop;

  -- (2) 미읽음 알림 합계
  select count(*) into v_notif
    from public.notifications n
   where n.user_id = v_user and n.is_read = false;

  -- (3) 캐시 갱신
  update public.users
     set unread_chat_count         = v_chat,
         unread_notification_count = v_notif
   where id = v_user;
end;
$$;


--
-- Name: FUNCTION reconcile_unread_counts(p_user_id uuid); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.reconcile_unread_counts(p_user_id uuid) IS '미읽음 채팅/알림 카운트 캐시를 source-of-truth(메시지/알림 테이블) 기준으로 재계산. 앱 진입·재연결·다중기기 동기화 직후 호출 권장';


--
-- Name: refresh_facility_aggs(uuid); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.refresh_facility_aggs(p_facility uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update public.facilities f set
    review_count = sub.cnt,
    avg_rating   = coalesce(round(sub.avg_r, 1), 0)
  from (select count(*) cnt, avg(rating)::numeric avg_r
          from public.facility_reviews
         where facility_id = p_facility and visibility_status = 'visible') sub
  where f.id = p_facility;
$$;


--
-- Name: tg_applications_block_insert(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_applications_block_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_owner          uuid;
  v_prog           text;
  v_vis            text;
  v_category       text;
  v_offered_status text;
  v_offered_role   text;
begin
  select user_id, progress_status, visibility_status, category
    into v_owner, v_prog, v_vis, v_category
    from public.posts where id = new.post_id;

  if v_owner is null then
    raise exception 'applications: 존재하지 않는 게시글';
  end if;
  if v_owner = new.applicant_id then
    raise exception 'applications: 본인 게시글에는 지원할 수 없습니다';
  end if;
  if v_vis like 'deleted_%' then
    raise exception 'applications: 삭제된 게시글에는 지원할 수 없습니다';
  end if;
  if v_prog <> 'recruiting' then
    raise exception 'applications: 모집이 마감된 게시글입니다 (progress=%)', v_prog;
  end if;
  if v_category = 'free' then
    raise exception 'applications: 자유 게시글은 지원 대상이 아닙니다';
  end if;

  -- 신청자가 게시글 펫의 보호자면 차단
  if exists (
    select 1 from public.post_pets pp
      join public.pet_guardians g on g.pet_id = pp.pet_id
     where pp.post_id = new.post_id and g.user_id = new.applicant_id
  ) then
    raise exception 'applications: 본인이 보호 중인 반려동물의 게시글에는 지원할 수 없습니다';
  end if;

  -- 게시글에 비활성 펫이 포함되어 있으면 신규 지원 차단
  if exists (
    select 1 from public.post_pets pp
      join public.pets p on p.id = pp.pet_id
     where pp.post_id = new.post_id and p.pet_status <> 'active'
  ) then
    raise exception 'applications: 비활성 반려동물이 포함된 게시글에는 지원할 수 없습니다';
  end if;

  -- 카테고리별 offered_pet_id 검증
  if v_category = 'adoption' then
    if new.offered_pet_id is null then
      raise exception 'applications: 입양 게시글은 분양할 반려동물(offered_pet_id) 지정이 필수입니다';
    end if;
    select pet_status into v_offered_status from public.pets where id = new.offered_pet_id;
    if v_offered_status is null then
      raise exception 'applications: 존재하지 않는 반려동물입니다';
    end if;
    if v_offered_status <> 'active' then
      raise exception 'applications: 활성 상태가 아닌 반려동물은 입양 글에 제안할 수 없습니다';
    end if;
    select role into v_offered_role
      from public.pet_guardians
     where pet_id = new.offered_pet_id and user_id = new.applicant_id;
    if v_offered_role is null or v_offered_role <> 'owner' then
      raise exception 'applications: 본인이 소유자(owner)인 반려동물만 입양 글에 제안할 수 있습니다';
    end if;
  else
    if new.offered_pet_id is not null then
      raise exception 'applications: 입양이 아닌 게시글에는 offered_pet_id 를 지정할 수 없습니다';
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: tg_applications_immutable_offer(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_applications_immutable_offer() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if old.offered_pet_id is distinct from new.offered_pet_id then
    raise exception 'applications: offered_pet_id 는 지원 후 변경할 수 없습니다';
  end if;
  return new;
end;
$$;


--
-- Name: tg_applications_on_accept(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_applications_on_accept() RETURNS trigger
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


--
-- Name: tg_appointments_after_update(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_appointments_after_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_category text;
  v_pet      uuid;
begin
  if old.status = 'scheduled' and new.status = 'completed' then
    update public.posts
       set progress_status = 'completed'
     where id = new.post_id and progress_status = 'matched';
    update public.applications
       set status = 'completed'
     where id = new.application_id and status = 'accepted';

    select category into v_category from public.posts where id = new.post_id;

    if v_category = 'give_away' then
      -- 분양: 글에 붙은 펫이 작성자(giver) → 지원자(receiver) 로
      select pet_id into v_pet from public.post_pets where post_id = new.post_id limit 1;
      if v_pet is not null then
        delete from public.pet_guardians where pet_id = v_pet;
        insert into public.pet_guardians (pet_id, user_id, role, invited_by)
        values (v_pet, new.applicant_id, 'owner', new.post_owner_id);
        update public.pets set primary_guardian_id = new.applicant_id where id = v_pet;
      end if;

    elsif v_category = 'adoption' then
      -- 입양: application 의 offered_pet 이 지원자(giver) → 작성자(adopter) 로
      select offered_pet_id into v_pet from public.applications where id = new.application_id;
      if v_pet is not null then
        delete from public.pet_guardians where pet_id = v_pet;
        insert into public.pet_guardians (pet_id, user_id, role, invited_by)
        values (v_pet, new.post_owner_id, 'owner', new.applicant_id);
        update public.pets set primary_guardian_id = new.post_owner_id where id = v_pet;
      end if;
    end if;

  elsif old.status = 'scheduled' and new.status = 'cancelled' then
    update public.posts
       set progress_status = 'recruiting'
     where id = new.post_id and progress_status = 'matched';
    update public.applications
       set status = 'cancelled'
     where id = new.application_id and status = 'accepted';
  end if;

  return new;
end;
$$;


--
-- Name: tg_appointments_before_update(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_appointments_before_update() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.status is distinct from old.status then
    if old.status in ('completed','cancelled') then
      raise exception 'appointments: % 상태는 변경 불가 (terminal)', old.status;
    end if;
    if not (old.status = 'scheduled' and new.status in ('completed','cancelled')) then
      raise exception 'appointments: 허용되지 않은 전이 % -> %', old.status, new.status;
    end if;
    if new.status = 'completed' and new.completed_at is null then
      new.completed_at := now();
    end if;
  end if;
  return new;
end;
$$;


--
-- Name: tg_appointments_pet_busy_check(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_appointments_pet_busy_check() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_conflict int;
begin
  if new.status = 'scheduled' then
    with new_pets as (
      select pp.pet_id from public.post_pets pp where pp.post_id = new.post_id
      union
      select app.offered_pet_id from public.applications app
        where app.id = new.application_id and app.offered_pet_id is not null
    )
    select count(*) into v_conflict
      from public.appointments a2
     where a2.status = 'scheduled'
       and a2.id <> new.id
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
      raise exception '이미 다른 약속이 진행 중인 반려동물이 게시글에 포함되어 있습니다';
    end if;
  end if;
  return new;
end;
$$;


--
-- Name: tg_audit_comments(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_audit_comments() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if app.is_admin() and old.is_deleted = false and new.is_deleted = true then
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(), 'delete_comment', 'comment', new.id,
            jsonb_build_object('post_id', new.post_id));
  end if;
  return new;
end;
$$;


--
-- Name: tg_audit_posts(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_audit_posts() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if app.is_admin()
     and new.visibility_status is distinct from old.visibility_status
     and new.visibility_status in ('hidden_by_admin','deleted_by_admin') then
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (
      app.uid(),
      case when new.visibility_status = 'deleted_by_admin' then 'delete_post' else 'hide_post' end,
      'post', new.id,
      jsonb_build_object(
        'before', jsonb_build_object('visibility_status', old.visibility_status),
        'after',  jsonb_build_object('visibility_status', new.visibility_status)
      )
    );
  end if;
  return new;
end;
$$;


--
-- Name: tg_audit_reports(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_audit_reports() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if app.is_admin() and new.status is distinct from old.status then
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(), 'update_report_status', 'report', new.id,
            jsonb_build_object('before', old.status, 'after', new.status));
  end if;
  return new;
end;
$$;


--
-- Name: tg_block_business_actor(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_block_business_actor() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform app.assert_personal_actor();
  return case tg_op when 'DELETE' then old else new end;
end;
$$;


--
-- Name: tg_chat_members_read(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_chat_members_read() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_old_ts  timestamptz;
  v_old_id  uuid;
  v_new_ts  timestamptz;
  v_new_id  uuid;
  v_newly   int;
  v_room    uuid;
begin
  if new.last_read_message_id is distinct from old.last_read_message_id
     and new.last_read_message_id is not null then

    -- room 일치 검증(같은 방의 메시지인지)
    select room_id, created_at, id
      into v_room, v_new_ts, v_new_id
      from public.chat_messages where id = new.last_read_message_id;
    if v_room is null or v_room <> new.room_id then
      raise exception 'chat_room_members: last_read_message_id 가 해당 방의 메시지가 아닙니다';
    end if;

    if old.last_read_message_id is not null then
      select created_at, id into v_old_ts, v_old_id
        from public.chat_messages where id = old.last_read_message_id;
    end if;

    -- 새로 읽은 (상대) 메시지 수 = (old, new] 구간 / 상대발신 / 미삭제
    select count(*) into v_newly
      from public.chat_messages msg
     where msg.room_id = new.room_id
       and msg.sender_id <> new.user_id
       and msg.is_deleted = false
       and (v_old_id is null
            or (msg.created_at, msg.id) > (v_old_ts, v_old_id))
       and (msg.created_at, msg.id) <= (v_new_ts, v_new_id);

    if v_newly > 0 then
      update public.users
         set unread_chat_count = greatest(unread_chat_count - v_newly, 0)
       where id = new.user_id;
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: tg_chat_messages_after_insert(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_chat_messages_after_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_preview text;
begin
  if new.content is not null then v_preview := left(new.content, 100);
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


--
-- Name: tg_chat_messages_after_softdelete(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_chat_messages_after_softdelete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if old.is_deleted = false and new.is_deleted = true then
    update public.chat_rooms
       set last_message_preview = '삭제된 메시지입니다.'
     where id = new.room_id and last_message_id = new.id;
  end if;
  return new;
end;
$$;


--
-- Name: tg_chat_messages_soft_delete_ts(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_chat_messages_soft_delete_ts() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if old.is_deleted = false and new.is_deleted = true and new.deleted_at is null then
    new.deleted_at := now();
  end if;
  return new;
end;
$$;


--
-- Name: tg_comments_count(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_comments_count() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if tg_op = 'INSERT' then
    if new.is_deleted = false then
      update public.posts set comment_count = comment_count + 1 where id = new.post_id;
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    -- soft delete 전환: -1
    if old.is_deleted = false and new.is_deleted = true then
      update public.posts set comment_count = greatest(comment_count - 1, 0) where id = new.post_id;
    -- 복원(드묾): +1
    elsif old.is_deleted = true and new.is_deleted = false then
      update public.posts set comment_count = comment_count + 1 where id = new.post_id;
    end if;
    return new;
  end if;
  return null;
end;
$$;


--
-- Name: tg_comments_soft_delete_ts(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_comments_soft_delete_ts() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if old.is_deleted = false and new.is_deleted = true and new.deleted_at is null then
    new.deleted_at := now();
  end if;
  return new;
end;
$$;


--
-- Name: tg_facility_review_aggs(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_facility_review_aggs() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform app.refresh_facility_aggs(coalesce(new.facility_id, old.facility_id));
  return null;
end $$;


--
-- Name: tg_facility_review_recall(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_facility_review_recall() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if old.visibility_status = 'visible' and new.visibility_status <> 'visible' then
    delete from public.notifications
     where notification_type = 'facility_review_received'
       and resource_id = new.id
       and is_read = false;
  end if;
  return new;
end;
$$;


--
-- Name: tg_frc_soft_delete_ts(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_frc_soft_delete_ts() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.is_deleted and not old.is_deleted then
    new.deleted_at := now();
  end if;
  return new;
end $$;


--
-- Name: tg_log_location_usage(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_log_location_usage() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  insert into app.location_usage_logs (user_id, purpose)
  values (new.user_id, tg_argv[0]);
  return null;
end;
$$;


--
-- Name: tg_notifications_read_ts(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notifications_read_ts() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if old.is_read = false and new.is_read = true and new.read_at is null then
    new.read_at := now();
  end if;
  return new;
end;
$$;


--
-- Name: tg_notifications_unread_count(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notifications_unread_count() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if tg_op = 'INSERT' then
    if new.is_read = false then
      update public.users set unread_notification_count = unread_notification_count + 1
       where id = new.user_id;
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    if old.is_read = false and new.is_read = true then
      update public.users set unread_notification_count = greatest(unread_notification_count - 1, 0)
       where id = new.user_id;
    elsif old.is_read = true and new.is_read = false then
      update public.users set unread_notification_count = unread_notification_count + 1
       where id = new.user_id;
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    if old.is_read = false then
      update public.users set unread_notification_count = greatest(unread_notification_count - 1, 0)
       where id = old.user_id;
    end if;
    return old;
  end if;
  return null;
end;
$$;


--
-- Name: tg_notify_application(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_application() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_owner uuid;
begin
  begin
    select user_id into v_owner from public.posts where id = new.post_id;
    if v_owner is not null and v_owner <> new.applicant_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title, resource_type, resource_id)
      values (v_owner, new.applicant_id, 'post_application', '내 게시글에 지원이 들어왔어요', 'post', new.post_id);
    end if;
  exception when others then null;
  end;
  return new;
end; $$;


--
-- Name: tg_notify_application_accepted(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_application_accepted() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  begin
    if new.status = 'accepted' and old.status is distinct from 'accepted' then
      insert into public.notifications(user_id, notification_type, title, resource_type, resource_id)
      values (new.applicant_id, 'application_accepted', '지원이 수락됐어요', 'post', new.post_id);
    end if;
  exception when others then null;
  end;
  return new;
end; $$;


--
-- Name: tg_notify_comment(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_comment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_owner uuid;
begin
  begin
    select user_id into v_owner from public.posts where id = new.post_id;
    if v_owner is not null and v_owner <> new.user_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title, resource_type, resource_id)
      values (v_owner, new.user_id, 'post_comment', '내 게시글에 새 댓글이 달렸어요', 'post', new.post_id);
    end if;
  exception when others then null;
  end;
  return new;
end; $$;


--
-- Name: tg_notify_facility_review(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_facility_review() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select bp.user_id, new.user_id, 'facility_review_received',
         '⭐ ' || u.nickname || '님이 방문 후기를 남겼어요',
         app.notif_trunc(
           '★' || new.rating ||
           case when coalesce(new.content, '') <> ''
                then ' · ' || new.content else '' end),
         'facility_review', new.id
    from public.business_profiles bp
    join public.users u on u.id = new.user_id
   where bp.status = 'approved'
     and bp.matched_facility_id = any(public.facility_sibling_ids(new.facility_id));
  return new;
end;
$$;


--
-- Name: tg_notify_guardian_invite(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_guardian_invite() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pet     text;
  v_inviter text;
begin
  begin
    if new.kind = 'invite'
       and new.invitee_user_id is not null
       and new.invitee_user_id <> new.inviter_id then
      select name     into v_pet     from public.pets  where id = new.pet_id;
      select nickname  into v_inviter from public.users where id = new.inviter_id;
      insert into public.notifications(user_id, actor_user_id, notification_type, title, body)
      values (
        new.invitee_user_id, new.inviter_id, 'guardian_invite',
        '공동보호자 초대가 왔어요',
        coalesce(v_inviter,'') || '님이 ' || coalesce(v_pet,'') || '의 공동보호자로 초대했어요'
      );
    end if;
  exception when others then null;
  end;
  return new;
end;
$$;


--
-- Name: tg_notify_pet_in_post(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_pet_in_post() RETURNS trigger
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


--
-- Name: tg_notify_review(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_review() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  begin
    if new.reviewee_id <> new.reviewer_id then
      insert into public.notifications(user_id, actor_user_id, notification_type, title)
      values (new.reviewee_id, new.reviewer_id, 'review_received', '새 후기를 받았어요');
    end if;
  exception when others then null;
  end;
  return new;
end; $$;


--
-- Name: tg_notify_review_comment(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notify_review_comment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_owner uuid;
begin
  begin
    select user_id into v_owner from public.facility_reviews where id = new.review_id;
    if v_owner is not null and v_owner <> new.user_id then
      insert into public.notifications(user_id, actor_user_id, notification_type,
                                       title, resource_type, resource_id)
      values (v_owner, new.user_id, 'review_comment',
              '내 후기에 새 댓글이 달렸어요', 'facility_review', new.review_id);
    end if;
  exception when others then null;
  end;
  return new;
end $$;


--
-- Name: tg_pawings_recall(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_pawings_recall() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  delete from public.notifications
   where notification_type = 'pawing_follow'
     and user_id = old.following_id
     and actor_user_id = old.follower_id
     and is_read = false;
  return old;
end;
$$;


--
-- Name: tg_pet_guardian_invites_respond(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_pet_guardian_invites_respond() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_new_guardian uuid;
begin
  if old.status = 'pending' and new.status = 'accepted' then
    if new.kind = 'invite' then
      v_new_guardian := new.invitee_user_id;   -- owner 가 초대 → 대상이 보호자
    else
      v_new_guardian := new.inviter_id;          -- 신청자가 요청 → 신청자가 보호자
    end if;
    if v_new_guardian is null then
      raise exception 'pet_guardian_invites: 수락 대상 사용자가 확정되지 않았습니다(미가입 전화)';
    end if;

    -- 진행 중 약속의 지원자가 그 펫의 보호자가 되려는 경우 차단
    if exists (
      select 1
        from public.appointments a
        join public.post_pets pp on pp.post_id = a.post_id
       where a.status = 'scheduled'
         and a.applicant_id = v_new_guardian
         and pp.pet_id = new.pet_id
    ) then
      raise exception '진행 중인 약속을 완료한 뒤에 보호자 초대를 수락할 수 있습니다';
    end if;

    insert into public.pet_guardians (pet_id, user_id, role, invited_by)
    values (new.pet_id, v_new_guardian, 'co_guardian', new.inviter_id)
    on conflict (pet_id, user_id) do nothing;
    new.responded_at := now();
  elsif old.status = 'pending' and new.status in ('declined','expired') then
    new.responded_at := now();
  end if;
  return new;
end;
$$;


--
-- Name: tg_pet_guardians_prevent_owner_self_remove(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_pet_guardians_prevent_owner_self_remove() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  -- 시스템(definer 분양 이전 등)은 app.uid()=NULL 또는 다른 컨텍스트라 우회 가능.
  -- 사용자 호출 컨텍스트(app.uid() is not null)에서만 강제.
  if old.role = 'owner' and app.uid() is not null and old.user_id = app.uid() then
    raise exception 'pet_guardians: owner 본인은 직접 제거할 수 없습니다. 먼저 소유권을 다른 보호자에게 이전하세요';
  end if;
  return old;
end;
$$;


--
-- Name: tg_pets_after_insert(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_pets_after_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  insert into public.pet_guardians (pet_id, user_id, role)
  values (new.id, new.primary_guardian_id, 'owner')
  on conflict (pet_id, user_id) do nothing;

  -- 펫을 등록하면 소유자가 되므로 작성 권한을 위해 user_type 승격
  update public.users
     set user_type = 'pet_owner'
   where id = new.primary_guardian_id
     and user_type is distinct from 'pet_owner';

  return new;
end;
$$;


--
-- Name: tg_pgi_resolve_invitee(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_pgi_resolve_invitee() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.invitee_user_id is null and new.invitee_phone is not null then
    select id into new.invitee_user_id
      from public.users
     where phone = new.invitee_phone;
  end if;

  -- 자기 자신 초대/요청 차단 (전화번호 resolve 후 최종 값 기준).
  if new.invitee_user_id = new.inviter_id then
    raise exception 'self_invite';
  end if;

  return new;
end;
$$;


--
-- Name: tg_post_hearts_count(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_post_hearts_count() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if tg_op = 'INSERT' then
    update public.posts set heart_count = heart_count + 1 where id = new.post_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.posts set heart_count = greatest(heart_count - 1, 0) where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;


--
-- Name: tg_post_hearts_recall(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_post_hearts_recall() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  delete from public.notifications
   where notification_type = 'post_heart'
     and actor_user_id = old.user_id
     and resource_id = old.post_id
     and is_read = false;
  return old;
end;
$$;


--
-- Name: tg_post_pets_giveaway_limit(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_post_pets_giveaway_limit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_category text;
  v_author   uuid;
  v_existing int;
  v_role     text;
begin
  select category, user_id into v_category, v_author
    from public.posts where id = new.post_id;

  -- 작성자가 해당 펫의 보호자인지(누구든 남의 펫을 붙이는 것 차단)
  select g.role into v_role
    from public.pet_guardians g
   where g.pet_id = new.pet_id and g.user_id = v_author;
  if v_role is null then
    raise exception 'post_pets: 본인이 보호 중인 반려동물만 게시글에 연결할 수 있습니다';
  end if;

  -- 분양: owner 만 + 정확히 1마리
  if v_category = 'give_away' then
    if v_role <> 'owner' then
      raise exception 'post_pets: 분양은 소유자(owner)만 해당 반려동물을 연결할 수 있습니다';
    end if;
    select count(*) into v_existing from public.post_pets where post_id = new.post_id;
    if v_existing >= 1 then
      raise exception 'post_pets: 분양 게시글은 반려동물 1마리만 연결 가능';
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: tg_post_views_count(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_post_views_count() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  update public.posts set view_count = view_count + 1 where id = new.post_id;
  return new;
end;
$$;


--
-- Name: tg_posts_block_trader(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_posts_block_trader() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.category in ('adoption', 'give_away') and exists (
    select 1 from public.business_profiles b
    where b.user_id = new.user_id and b.status = 'approved'
  ) then
    raise exception 'posts: 영업자 계정은 분양·입양 글을 작성할 수 없어요';
  end if;
  return new;
end;
$$;


--
-- Name: tg_posts_check_write(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_posts_check_write() RETURNS trigger
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


--
-- Name: tg_posts_deleted_at(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_posts_deleted_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.visibility_status like 'deleted_%' then
    if new.deleted_at is null then
      new.deleted_at := now();
    end if;
  else
    new.deleted_at := null;
  end if;
  return new;
end;
$$;


--
-- Name: tg_posts_set_region(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_posts_set_region() RETURNS trigger
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


--
-- Name: tg_posts_validate_transition(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_posts_validate_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  -- visibility_status 전이
  if new.visibility_status is distinct from old.visibility_status then
    if old.visibility_status like 'deleted_%' then
      raise exception 'posts: deleted 상태는 변경 불가 (terminal)';
    end if;
    if not (
      (old.visibility_status = 'visible'         and new.visibility_status in ('hidden_by_user','hidden_by_admin','deleted_by_user','deleted_by_admin')) or
      (old.visibility_status = 'hidden_by_user'  and new.visibility_status in ('visible','deleted_by_user')) or
      (old.visibility_status = 'hidden_by_admin' and new.visibility_status in ('visible','deleted_by_admin'))
    ) then
      raise exception 'posts: 허용되지 않은 visibility_status 전이 % -> %',
        old.visibility_status, new.visibility_status;
    end if;
  end if;

  -- progress_status 전이
  if new.progress_status is distinct from old.progress_status then
    if old.progress_status in ('completed','cancelled') then
      raise exception 'posts: % 상태는 변경 불가 (terminal)', old.progress_status;
    end if;
    if not (
      (old.progress_status = 'recruiting' and new.progress_status in ('matched','cancelled')) or
      (old.progress_status = 'matched'    and new.progress_status in ('completed','recruiting'))
    ) then
      raise exception 'posts: 허용되지 않은 progress_status 전이 % -> %',
        old.progress_status, new.progress_status;
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: tg_reviews_aggregate(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_reviews_aggregate() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_cat text;
begin
  foreach v_cat in array new.categories loop
    insert into public.review_category_counts (user_id, category, count, updated_at)
    values (new.reviewee_id, v_cat, 1, now())
    on conflict (user_id, category)
    do update set count = review_category_counts.count + 1, updated_at = now();
  end loop;
  return new;
end;
$$;


--
-- Name: tg_reviews_grant_pet_trust(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_reviews_grant_pet_trust() RETURNS trigger
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


--
-- Name: tg_reviews_validate(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_reviews_validate() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_owner     uuid;
  v_applicant uuid;
  v_status    text;
begin
  select post_owner_id, applicant_id, status
    into v_owner, v_applicant, v_status
    from public.appointments where id = new.appointment_id;

  if v_owner is null then
    raise exception 'reviews: 존재하지 않는 약속';
  end if;
  if v_status <> 'completed' then
    raise exception 'reviews: 완료된 약속에만 평가를 작성할 수 있습니다';
  end if;

  -- reviewer/reviewee 는 약속 당사자 쌍이어야 함
  if not (
    (new.reviewer_id = v_owner     and new.reviewee_id = v_applicant) or
    (new.reviewer_id = v_applicant and new.reviewee_id = v_owner)
  ) then
    raise exception 'reviews: 약속 당사자만 서로 평가할 수 있습니다';
  end if;

  -- TEXT[] 중복 값 차단
  if array_length(array(select distinct unnest(new.categories)), 1)
       <> array_length(new.categories, 1) then
    raise exception 'reviews: 카테고리에 중복 값이 있습니다';
  end if;

  return new;
end;
$$;


--
-- Name: tg_set_updated_at(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: tg_users_after_insert(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_users_after_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_room_id uuid;
begin
  -- 알림 설정 기본 행
  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  -- 관리자 문의 채팅방 (admin 계정 제외)
  if new.user_type <> 'admin' then
    insert into public.chat_rooms (room_type, canonical_key)
    values ('admin_inquiry', 'admin_' || new.id::text)
    on conflict (canonical_key) do nothing
    returning id into v_room_id;

    if v_room_id is not null then
      insert into public.chat_room_members (room_id, user_id)
      values (v_room_id, new.id)
      on conflict (room_id, user_id) do nothing;
    end if;
  end if;

  -- 내 전화번호로 와 있던 대기 초대(invite)에 invitee_user_id 연결 → 가입 후 수락 가능
  if new.phone is not null then
    update public.pet_guardian_invites
       set invitee_user_id = new.id
     where invitee_phone = new.phone
       and status = 'pending'
       and invitee_user_id is null;

    -- 방금 연결된 대기 초대들에 대해 알림 생성
    begin
      insert into public.notifications(user_id, actor_user_id, notification_type, title, body)
      select i.invitee_user_id, i.inviter_id, 'guardian_invite',
             '공동보호자 초대가 왔어요',
             coalesce(u.nickname,'') || '님이 ' || coalesce(p.name,'') || '의 공동보호자로 초대했어요'
        from public.pet_guardian_invites i
        join public.pets  p on p.id = i.pet_id
        left join public.users u on u.id = i.inviter_id
       where i.invitee_user_id = new.id
         and i.status = 'pending'
         and i.kind = 'invite'
         and i.invitee_user_id <> i.inviter_id;
    exception when others then null;
    end;
  end if;

  return new;
end;
$$;


--
-- Name: tg_users_owner_succession(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_users_owner_succession() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pet  uuid;
  v_heir uuid;
begin
  -- active → inactive/suspended 전이일 때만 동작
  if not (old.status = 'active' and new.status in ('inactive','suspended')) then
    return new;
  end if;

  -- 떠나는 사용자가 owner 인 펫 각각에 대해 처리
  for v_pet in
    select pet_id from public.pet_guardians
     where user_id = new.id and role = 'owner'
  loop
    -- 가장 먼저 들어온 co_guardian(연동 순서 우선) 후보 선정
    select user_id into v_heir
      from public.pet_guardians
     where pet_id = v_pet
       and role  = 'co_guardian'
       and user_id <> new.id
     order by created_at asc, id asc
     limit 1;

    if v_heir is not null then
      -- ① 떠나는 owner 를 먼저 co_guardian 으로 강등 (one_owner partial unique 충돌 방지)
      update public.pet_guardians
         set role = 'co_guardian'
       where pet_id = v_pet and user_id = new.id;
      -- ② 후계자 승격
      update public.pet_guardians
         set role = 'owner'
       where pet_id = v_pet and user_id = v_heir;
      -- ③ 소유자 포인터 갱신
      update public.pets
         set primary_guardian_id = v_heir
       where id = v_pet;
    else
      -- 후계 없음 → 펫 비활성화. (떠나는 사용자를 먼저 co_guardian 으로 강등해야
      -- 다음 단계의 DELETE 가 prevent-owner-self-remove 트리거에 막히지 않음.)
      update public.pet_guardians
         set role = 'co_guardian'
       where pet_id = v_pet and user_id = new.id;
      update public.pets
         set pet_status = 'deleted'
       where id = v_pet;
      -- primary_guardian_id 는 NOT NULL 이라 비활성 사용자 가리킴 그대로 둠
      -- (펫이 비활성이라 신규 활동에는 사용되지 않음 — 이력 보존용 참조만 유지)
    end if;
  end loop;

  -- 떠나는 사용자의 모든 보호자 행 정리 (owner 였던 펫은 위에서 강등됐고,
  -- 원래 co_guardian 이던 펫은 그대로 남아 있던 것을 일괄 제거)
  delete from public.pet_guardians where user_id = new.id;

  return new;
end;
$$;


--
-- Name: uid(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.uid() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select u.id
  from public.users u
  where u.id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'sub','')::uuid
    and u.status = 'active'
    and u.token_version = coalesce(
      ((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'tv')::int, 0)
$$;


--
-- Name: _push_pref_allows(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._push_pref_allows(p_user uuid, p_type text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce((
    select case p_type
      when 'chat_message' then chat_message
      when 'post_application' then post_application
      when 'post_comment' then post_comment
      when 'review_comment' then post_comment
      when 'pawing_new_post' then pawing_new_post
      when 'application_accepted' then application_accepted
      when 'review_received' then review_received
      when 'system_notice' then system_notice
      else true
    end
    from public.notification_preferences where user_id = p_user
  ), true)
$$;


--
-- Name: add_facility_review(uuid, smallint, text, text[], text[], boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_facility_review(p_facility uuid, p_rating smallint, p_body text, p_paths text[] DEFAULT '{}'::text[], p_urls text[] DEFAULT '{}'::text[], p_has_incentive boolean DEFAULT false) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_uid uuid := app.uid(); v_id uuid;
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
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls, has_incentive)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'), coalesce(p_has_incentive, false))
  returning id into v_id;
  return v_id;
end $$;


--
-- Name: admin_broadcast_system_notice(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_broadcast_system_notice(p_title text, p_body text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_cnt int;
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if p_title is null or length(btrim(p_title)) = 0 or length(p_title) > 80 then
    raise exception 'invalid_title' using errcode='P0001';
  end if;
  if p_body is null or length(btrim(p_body)) = 0 or length(p_body) > 1000 then
    raise exception 'invalid_body' using errcode='P0001';
  end if;

  -- 정지(suspended)·휴면(inactive) 회원도 약관 개정 고지 대상 — 탈퇴자만 제외.
  insert into public.notifications (user_id, notification_type, is_system, title, body)
  select u.id, 'system_notice', true, btrim(p_title), btrim(p_body)
    from public.users u
   where u.status <> 'deleted';
  get diagnostics v_cnt = row_count;

  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'broadcast_system_notice', 'system', null,
          jsonb_build_object('title', btrim(p_title), 'recipients', v_cnt));

  return v_cnt;
end $$;


--
-- Name: admin_create_facility_share_link(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_create_facility_share_link(p_facility uuid, p_days integer DEFAULT 365) RETURNS TABLE(token character varying, expires_at timestamp with time zone)
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


--
-- Name: admin_dashboard_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_dashboard_stats() RETURNS json
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v json;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select json_build_object(
    'users',                  (select count(*) from public.users),
    'users_suspended',        (select count(*) from public.users where status = 'suspended'),
    'posts',                  (select count(*) from public.posts where deleted_at is null),
    'appointments_scheduled', (select count(*) from public.appointments where status = 'scheduled'),
    'reports_open',           (select count(*) from public.reports where status in ('submitted','reviewing'))
  ) into v;
  return v;
end;
$$;


--
-- Name: admin_get_report_target(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_report_target(p_report uuid) RETURNS json
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: admin_join_inquiry(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_join_inquiry(p_room uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists (select 1 from public.chat_rooms where id=p_room and room_type='admin_inquiry') then
    raise exception 'not_inquiry_room' using errcode='P0001';
  end if;
  insert into public.chat_room_members(room_id, user_id)
  values (p_room, app.uid())
  on conflict (room_id, user_id) do nothing;
end;
$$;


--
-- Name: admin_list_business_applications(text, text, boolean, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_business_applications(p_status text DEFAULT 'pending'::text, p_track text DEFAULT NULL::text, p_auto_only boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(user_id uuid, nickname text, business_reg_no text, declared_category text, business_name text, storefront_name text, prev_business_name text, business_address text, business_address_jibun text, business_phone text, representative_name text, contact_email text, license_image_path text, extra_doc_path text, nts_status_code text, nts_checked_at timestamp with time zone, matched_facility_id uuid, matched_facility_name text, matched_biz_key text, match_score integer, match_detail jsonb, review_track text, auto_approved boolean, status text, rejected_reason text, review_note text, reviewed_by uuid, reviewed_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('pending','approved','rejected') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  if p_track is not null and p_track not in ('auto','review','new_business') then
    raise exception 'invalid_track' using errcode = 'P0001';
  end if;
  return query
  select bp.user_id, u.nickname::text, bp.business_reg_no::text, bp.declared_category::text,
         bp.business_name, bp.storefront_name, bp.prev_business_name,
         bp.business_address, bp.business_address_jibun, bp.business_phone::text,
         bp.representative_name, bp.contact_email,
         bp.license_image_path, bp.extra_doc_path,
         bp.nts_status_code::text, bp.nts_checked_at,
         bp.matched_facility_id, f.name::text, bp.matched_biz_key,
         bp.match_score, bp.match_detail, bp.review_track::text, bp.auto_approved,
         bp.status::text, bp.rejected_reason, bp.review_note,
         bp.reviewed_by, bp.reviewed_at, bp.created_at, bp.updated_at
    from public.business_profiles bp
    join public.users u on u.id = bp.user_id
    left join public.facilities f on f.id = bp.matched_facility_id
   where (p_status is null or bp.status = p_status)
     and (p_track is null or bp.review_track = p_track)
     and (not p_auto_only or bp.auto_approved)
   order by bp.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 100))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;


--
-- Name: admin_list_business_licenses(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_business_licenses(p_status text DEFAULT 'pending'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, user_id uuid, nickname text, business_name text, license_type text, license_no text, document_path text, status text, reject_reason text, created_at timestamp with time zone, reviewed_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select l.id, l.user_id, u.nickname::text, b.business_name::text,
         l.license_type::text, l.license_no::text, l.document_path,
         l.status::text, l.reject_reason, l.created_at, l.reviewed_at
    from app.business_licenses l
    join public.users u on u.id = l.user_id
    left join public.business_profiles b on b.user_id = l.user_id
   where (p_status is null or l.status = p_status)
   order by l.created_at
   limit least(coalesce(p_limit, 50), 200) offset coalesce(p_offset, 0);
end;
$$;


--
-- Name: admin_list_comments(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_comments(p_post uuid) RETURNS TABLE(id uuid, content text, author_id uuid, author_nickname text, is_deleted boolean, created_at timestamp with time zone)
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


--
-- Name: admin_list_inquiries(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_inquiries() RETURNS TABLE(room_id uuid, user_id uuid, user_nickname text, last_message text, last_message_at timestamp with time zone)
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


--
-- Name: admin_list_logs(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_logs(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, admin_id uuid, admin_nickname text, action_type text, target_type text, target_id uuid, detail jsonb, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: admin_list_posts(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_posts(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, title text, content text, category text, author_id uuid, author_nickname text, visibility_status text, heart_count integer, comment_count integer, view_count integer, created_at timestamp with time zone)
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


--
-- Name: admin_list_reports(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_reports(p_status text DEFAULT 'open'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, target_type text, target_id uuid, categories text[], extra_description text, status text, created_at timestamp with time zone, reviewed_at timestamp with time zone, reporter_id uuid, reporter_nickname text)
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


--
-- Name: admin_list_users(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_users(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, username text, nickname text, user_type text, status text, phone text, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: admin_location_usage_logs(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_location_usage_logs(p_user uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS TABLE(user_id uuid, purpose text, provided_to text, used_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select l.user_id, l.purpose, l.provided_to, l.used_at
    from app.location_usage_logs l
   where l.user_id = p_user
   order by l.used_at desc
   limit greatest(1, least(coalesce(p_limit,100), 500))
   offset greatest(0, coalesce(p_offset,0));
end;
$$;


--
-- Name: admin_ops_metrics(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_ops_metrics() RETURNS json
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


--
-- Name: admin_photo_verification_failures(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_photo_verification_failures(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, created_at timestamp with time zone, fail_reason text, ai_reason text, region_matched boolean, ai_match_score numeric, purpose text, nickname text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select pv.id, pv.created_at, pv.fail_reason::text, pv.ai_reason::text,
         pv.region_matched, pv.ai_match_score, pv.purpose::text,
         coalesce(u.nickname, '알 수 없음')::text
  from public.photo_verifications pv
  left join public.users u on u.id = pv.user_id
  where pv.result = 'fail'
  order by pv.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;


--
-- Name: admin_review_business_license(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_review_business_license(p_license uuid, p_status text, p_reason text DEFAULT NULL::text) RETURNS void
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


--
-- Name: admin_revoke_share_link(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_revoke_share_link(p_token character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update app.share_links set revoked_at = now()
  where token = p_token and revoked_at is null;
  return found;
end;
$$;


--
-- Name: admin_room_messages(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_room_messages(p_room uuid, p_limit integer DEFAULT 200) RETURNS TABLE(id uuid, sender_id uuid, sender_nickname text, content text, image_url text, is_deleted boolean, deleted_at timestamp with time zone, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: admin_set_business_status(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_business_status(p_user uuid, p_status text, p_reason text DEFAULT NULL::text) RETURNS void
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


--
-- Name: admin_set_chat_message_deleted(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_chat_message_deleted(p_message uuid, p_deleted boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: admin_set_comment_deleted(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_comment_deleted(p_comment uuid, p_deleted boolean) RETURNS void
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


--
-- Name: admin_set_match_rule(text, integer, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_match_rule(p_key text, p_weight integer DEFAULT NULL::integer, p_enabled boolean DEFAULT NULL::boolean, p_params jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_before public.business_match_rules%rowtype;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_before from public.business_match_rules where rule_key = p_key;
  if not found then
    raise exception 'rule_not_found' using errcode = 'P0001';
  end if;

  update public.business_match_rules set
    weight = coalesce(p_weight, weight),
    enabled = coalesce(p_enabled, enabled),
    params = coalesce(p_params, params),
    updated_at = now()
  where rule_key = p_key;

  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'set_business_match_rule', 'system', null,
          jsonb_build_object('rule_key', p_key,
            'before', jsonb_build_object('weight', v_before.weight, 'enabled', v_before.enabled, 'params', v_before.params),
            'after',  jsonb_build_object('weight', coalesce(p_weight, v_before.weight),
                                         'enabled', coalesce(p_enabled, v_before.enabled),
                                         'params', coalesce(p_params, v_before.params))));
end;
$$;


--
-- Name: admin_set_post_visibility(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_post_visibility(p_post uuid, p_visibility text) RETURNS void
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


--
-- Name: admin_set_report_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_report_status(p_report uuid, p_status text) RETURNS void
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


--
-- Name: admin_set_user_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_user_status(p_user uuid, p_status text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: apply_business_license(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_business_license(p_type text, p_license_no text, p_document_path text) RETURNS uuid
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
                 where b.user_id = v_uid and b.status = 'approved') then
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


--
-- Name: apply_business_profile(uuid, text, text, text, text, text, text, text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_business_profile(p_user uuid, p_b_no text, p_category text, p_business_name text, p_storefront_name text, p_prev_name text, p_address_road text, p_address_jibun text, p_region_code text, p_phone text, p_rep_name text, p_email text, p_license_path text, p_extra_doc_path text, p_nts_status_code text) RETURNS jsonb
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


--
-- Name: bump_token_version(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bump_token_version(p_user uuid) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update public.users set token_version = token_version + 1 where id = p_user returning token_version;
$$;


--
-- Name: business_doc_purge_done(bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_doc_purge_done(p_ids bigint[]) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update app.business_doc_purge_queue
     set purged_at = now()
   where id = any(p_ids) and purged_at is null;
$$;


--
-- Name: business_doc_purge_take(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_doc_purge_take(p_limit integer DEFAULT 200) RETURNS TABLE(id bigint, path text)
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


--
-- Name: can_manage_post_applicants(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_post_applicants(p_post uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select app.is_post_manager(p_post)
$$;


--
-- Name: change_password_and_rotate(uuid, text, text, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.change_password_and_rotate(p_user uuid, p_current_hash text, p_new_hash text, p_tv integer, p_new_token_hash text, p_user_agent text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_tv integer;
begin
  if p_user is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- 세션 유효성(정지/전역 무효화 반영) — app.uid 게이트와 동일 기준.
  if not exists (
    select 1 from public.users
    where id = p_user and status = 'active' and token_version = coalesce(p_tv, 0)
  ) then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- 비번 갱신(CAS). 0행이면 검증 시점과 해시가 달라진 것 → invalid_current 로 롤백.
  update public.users set password_hash = p_new_hash
   where id = p_user and password_hash = p_current_hash;
  if not found then
    raise exception 'invalid_current' using errcode = 'P0001';
  end if;

  -- 전 세션 무효화: token_version bump + 모든 refresh 회수
  update public.users set token_version = token_version + 1
   where id = p_user
   returning token_version into v_tv;
  update app.refresh_tokens set revoked_at = now()
   where user_id = p_user and revoked_at is null;

  -- 현재 기기용 새 refresh family 발급
  insert into app.refresh_tokens(
    user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent
  ) values (
    p_user, p_new_token_hash, gen_random_uuid(),
    now() + interval '30 days', now() + interval '90 days', p_user_agent
  );

  return v_tv;
end;
$$;


--
-- Name: check_nickname_available(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_nickname_available(p_nickname text) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select not exists (
    select 1 from public.users
    where lower(nickname) = lower(trim(p_nickname))
      and id is distinct from app.uid()
  );
$$;


--
-- Name: check_username_available(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_username_available(p_username text) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select not exists (
    select 1 from public.users where lower(username) = lower(p_username)
  );
$$;


--
-- Name: create_post_verified(character varying, character varying, text, timestamp with time zone, uuid[], text, character varying, integer, uuid, double precision, double precision, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_post_verified(p_category character varying, p_title character varying, p_content text, p_scheduled_at timestamp with time zone, p_pet_ids uuid[], p_image_url text, p_image_mime character varying, p_image_size integer, p_photo_token uuid DEFAULT NULL::uuid, p_actual_lat double precision DEFAULT NULL::double precision, p_actual_lng double precision DEFAULT NULL::double precision, p_region_code character varying DEFAULT NULL::character varying) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
    image_url, image_mime_type, image_file_size,
    actual_lat, actual_lng, region_code
  ) values (
    v_uid, p_category, p_title, p_content, p_scheduled_at,
    p_image_url, p_image_mime, p_image_size,
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


--
-- Name: delete_facility_review(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_facility_review(p_facility uuid, p_review uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_uid uuid := app.uid();
begin
  if v_uid is null then raise exception 'auth required'; end if;
  update public.facility_reviews
     set visibility_status = 'deleted_by_user', updated_at = now()
   where facility_id = any(public.facility_sibling_ids(p_facility))
     and user_id = v_uid
     and (p_review is null or id = p_review);
end $$;


--
-- Name: delete_my_chat_message(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_my_chat_message(p_message uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: delete_my_post(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_my_post(p_post uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: dong_centroid_seeds(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dong_centroid_seeds() RETURNS TABLE(region_code character varying, seed_lng double precision, seed_lat double precision)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select u.region_code, avg(u.longitude), avg(u.latitude)
    from public.users u
   where u.region_code is not null and u.latitude is not null and u.longitude is not null
     and not exists (select 1 from public.dong_centroids d where d.region_code = u.region_code)
   group by u.region_code
   limit 100;
$$;


--
-- Name: enroll_pet_identity(uuid, character varying, text[], text[], character varying, text[], jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enroll_pet_identity(p_pet uuid, p_species character varying, p_paths text[], p_urls text[], p_breed character varying DEFAULT NULL::character varying, p_colors text[] DEFAULT NULL::text[], p_info_match jsonb DEFAULT NULL::jsonb) RETURNS void
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


--
-- Name: ensure_naver_facility(text, text, text, double precision, double precision); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_naver_facility(p_name text, p_address text, p_phone text, p_lng double precision, p_lat double precision) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_ext text; v_id uuid;
begin
  if app.uid() is null then raise exception 'auth required'; end if;
  v_ext := md5(lower(regexp_replace(coalesce(p_name,'')||'|'||coalesce(p_address,''), '\s', '', 'g')));
  insert into public.facilities (category, source, ext_id, name, address, phone, is_open, geom)
  values ('pet_cafe', 'naver', v_ext, p_name, p_address, p_phone, true,
          public.st_setsrid(public.st_makepoint(p_lng, p_lat), 4326)::public.geography)
  on conflict (source, ext_id) do update set name = excluded.name
  returning id into v_id;
  return v_id;
end $$;


--
-- Name: facilities_search(text, double precision, double precision); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facilities_search(p_query text, p_lng double precision DEFAULT NULL::double precision, p_lat double precision DEFAULT NULL::double precision) RETURNS TABLE(id uuid, category public.facility_category, name character varying, address text, phone character varying, is_open boolean, lng double precision, lat double precision, distance_m double precision, source character varying, avg_rating numeric, review_count integer, owner_photo_url text, owner_photo_align_y real, owner_user_id uuid, business_hours character varying, owner_verified_at timestamp with time zone, categories text[])
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select r.id, r.category, r.name, r.address, r.phone, r.is_open,
         r.lng, r.lat, r.distance_m, r.source,
         r.avg_rating, r.review_count,
         r.owner_photo_url, r.owner_photo_align_y, r.owner_user_id,
         r.business_hours, r.owner_verified_at, r.categories
    from (
      select distinct on (sib.canonical)
             f.id, f.category, f.name, f.address, f.phone, f.is_open,
             st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
             f.distance_m, f.source,
             coalesce(sib.avg_rating, 0) as avg_rating,
             coalesce(sib.review_count, 0) as review_count,
             ob.photo_url as owner_photo_url,
             coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
             ob.user_id as owner_user_id,
             ob.business_hours,
             ob.reviewed_at as owner_verified_at,
             sib.categories
        from (
          select f0.*,
                 case when p_lng is not null and p_lat is not null
                      then st_distance(f0.geom, st_makepoint(p_lng, p_lat)::geography)
                 end as distance_m
            from public.facilities f0
           where f0.is_open and f0.geom is not null
             and f0.name ilike '%' || p_query || '%'
           order by distance_m nulls last, f0.name limit 30
        ) f
        left join lateral (
          select array_agg(s.id) as ids,
                 min(s.id::text) as canonical,
                 array_agg(distinct s.category::text) as categories,
                 sum(s.review_count)::int as review_count,
                 case when sum(s.review_count) > 0
                      then round(sum(s.avg_rating * s.review_count)::numeric
                                 / sum(s.review_count), 1)
                 end as avg_rating
            from public.facilities s
           where s.id = f.id
              or (s.geom is not null and st_dwithin(s.geom, f.geom, 50)
                  and (s.name = f.name
                       or (f.phone is not null and s.phone = f.phone)
                       or (length(f.name) >= 3 and length(s.name) >= 3
                           and (s.name ilike '%' || f.name || '%'
                                or f.name ilike '%' || s.name || '%'))))
        ) sib on true
        left join lateral (
          select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
                 bp.business_hours
            from public.business_profiles bp
           where bp.status = 'approved'
             and bp.matched_facility_id = any(sib.ids)
           order by bp.reviewed_at asc nulls last
           limit 1
        ) ob on true
        order by sib.canonical,
                 (ob.user_id is not null) desc,
                 f.distance_m nulls last, f.id
    ) r
   order by r.distance_m nulls last, r.name;
$$;


--
-- Name: facilities_within(double precision, double precision, integer, public.facility_category[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer DEFAULT 5000, p_categories public.facility_category[] DEFAULT NULL::public.facility_category[]) RETURNS TABLE(id uuid, category public.facility_category, name character varying, address text, phone character varying, is_open boolean, lng double precision, lat double precision, distance_m double precision, source character varying, avg_rating numeric, review_count integer, owner_photo_url text, owner_photo_align_y real, owner_user_id uuid, business_hours character varying, owner_verified_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         f.distance_m, f.source,
         coalesce(sib.avg_rating, 0) as avg_rating,
         coalesce(sib.review_count, 0) as review_count,
         ob.photo_url as owner_photo_url,
         coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
         ob.user_id as owner_user_id,
         ob.business_hours,
         ob.reviewed_at as owner_verified_at
    from (
      select f0.*,
             st_distance(f0.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m
        from public.facilities f0
       where f0.is_open and f0.geom is not null
         and (p_categories is null or f0.category = any(p_categories))
         and st_dwithin(f0.geom, st_makepoint(p_lng, p_lat)::geography,
                        least(coalesce(p_radius_m, 5000), 5000))
       order by distance_m limit 500
    ) f
    left join lateral (
      select array_agg(s.id) as ids,
             sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or (s.geom is not null and st_dwithin(s.geom, f.geom, 50)
              and (s.name = f.name
                   or (f.phone is not null and s.phone = f.phone)
                   or (length(f.name) >= 3 and length(s.name) >= 3
                       and (s.name ilike '%' || f.name || '%'
                            or f.name ilike '%' || s.name || '%'))))
    ) sib on true
    left join lateral (
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
       where bp.status = 'approved'
         and bp.matched_facility_id = any(sib.ids)
       order by bp.reviewed_at asc nulls last
       limit 1
    ) ob on true
   order by f.distance_m;
$$;


--
-- Name: facility_all_categories(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facility_all_categories(p_id uuid) RETURNS text[]
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(array_agg(distinct s.category::text order by s.category::text),
                  array[]::text[])
    from facilities s
   where s.id = any(public.facility_sibling_ids(p_id));
$$;


--
-- Name: facility_review_by_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facility_review_by_id(p_review uuid) RETURNS TABLE(id uuid, user_id uuid, author_nickname text, rating smallint, content text, photo_urls text[], created_at timestamp with time zone, is_mine boolean, visit_no integer, has_incentive boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no, r.has_incentive
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


--
-- Name: facility_reviews_of(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS TABLE(id uuid, user_id uuid, author_nickname text, rating smallint, content text, photo_urls text[], created_at timestamp with time zone, is_mine boolean, visit_no integer, has_incentive boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no, r.has_incentive
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


--
-- Name: facility_sibling_ids(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facility_sibling_ids(p_id uuid) RETURNS uuid[]
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(array_agg(s.id), array[p_id])
    from facilities f
    join facilities s
      on s.id = f.id
      or (f.geom is not null and s.geom is not null
          and st_dwithin(s.geom, f.geom, 50)
          and (s.name = f.name
               or (f.phone is not null and s.phone = f.phone)
               or (length(f.name) >= 3 and length(s.name) >= 3
                   and (s.name ilike '%' || f.name || '%'
                        or f.name ilike '%' || s.name || '%'))))
   where f.id = p_id;
$$;


--
-- Name: feed_region_codes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.feed_region_codes() RETURNS text[]
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with me as (
    select latitude as lat, longitude as lng, activity_radius_m as r,
           is_location_verified as v
      from public.users where id = app.uid()
  ),
  uavg as (
    select region_code, avg(longitude) as lng, avg(latitude) as lat
      from public.users
     where region_code is not null and latitude is not null and longitude is not null
     group by region_code
  )
  select case
    when (select r from me) is null
      or not (select coalesce(v,false) from me)
      or (select lat from me) is null then null
    else coalesce((
      select array_agg(distinct p.region_code)
        from public.posts p
        left join public.dong_centroids d on d.region_code = p.region_code
        left join uavg u on u.region_code = p.region_code
        cross join me
       where p.visibility_status = 'visible' and p.region_code is not null
         and coalesce(d.lng, u.lng) is not null
         and public.st_distance(
               public.st_makepoint(coalesce(d.lng,u.lng), coalesce(d.lat,u.lat))::public.geography,
               public.st_makepoint(me.lng, me.lat)::public.geography) <= me.r
    ), array[]::text[])
  end;
$$;


--
-- Name: get_login_user(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_login_user(p_username text) RETURNS TABLE(id uuid, username text, nickname text, user_type text, password_hash text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select u.id, u.username::text, u.nickname::text, u.user_type::text, u.password_hash::text
  from public.users u
  where lower(u.username) = lower(p_username)
    and u.status = 'active';
$$;


--
-- Name: get_password_hash(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_password_hash(p_user uuid) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select u.password_hash::text from public.users u
  where u.id = p_user and u.status = 'active';
$$;


--
-- Name: leave_chat_room(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.leave_chat_room(p_room uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_me uuid := app.uid();
  v_last uuid;
  v_type text;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = 'P0001'; end if;

  select room_type::text, last_message_id into v_type, v_last
    from public.chat_rooms where id = p_room;
  if v_type = 'admin_inquiry' then
    raise exception '고객센터 채팅방은 나갈 수 없어요' using errcode = 'P0001';
  end if;

  update public.chat_room_members
     set left_at = now(),
         last_read_message_id = coalesce(v_last, last_read_message_id),
         updated_at = now()
   where room_id = p_room and user_id = v_me;
  if not found then raise exception 'not_a_member' using errcode = 'P0001'; end if;
end $$;


--
-- Name: login_issue_refresh(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.login_issue_refresh(p_user uuid, p_token_hash text, p_user_agent text DEFAULT NULL::text) RETURNS integer
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


--
-- Name: my_business_licenses(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_business_licenses() RETURNS TABLE(id uuid, license_type text, license_no text, status text, reject_reason text, created_at timestamp with time zone, reviewed_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select l.id, l.license_type::text, l.license_no::text, l.status::text,
         l.reject_reason, l.created_at, l.reviewed_at
    from app.business_licenses l
   where l.user_id = app.uid()
   order by l.created_at;
$$;


--
-- Name: naver_facility_id(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.naver_facility_id(p_name text, p_address text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select id from public.facilities
   where source = 'naver'
     and ext_id = md5(lower(regexp_replace(coalesce(p_name,'')||'|'||coalesce(p_address,''), '\s', '', 'g')))
   limit 1;
$$;


--
-- Name: pet_guardians_of(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pet_guardians_of(p_pet uuid) RETURNS TABLE(user_id uuid, nickname text, profile_image_url text, role text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select g.user_id, u.nickname::text, u.profile_image_url, g.role::text
  from public.pet_guardians g
  join public.users u on u.id = g.user_id
  where g.pet_id = p_pet
    and u.deleted_at is null
    and u.status = 'active'
    and exists (
      select 1 from public.pets p
      where p.id = p_pet and p.pet_status <> 'deleted'
    )
  order by (g.role = 'owner') desc, g.created_at
$$;


--
-- Name: posts_by_region(double precision, double precision, double precision, double precision); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.posts_by_region(p_min_lng double precision, p_min_lat double precision, p_max_lng double precision, p_max_lat double precision) RETURNS TABLE(region_code character varying, post_count bigint, lng double precision, lat double precision, post_ids uuid[])
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with uavg as (
    select region_code, avg(longitude) as lng, avg(latitude) as lat
      from public.users
     where region_code is not null and latitude is not null and longitude is not null
     group by region_code
  )
  select p.region_code, count(*)::bigint as post_count,
         coalesce(d.lng, u.lng) as lng, coalesce(d.lat, u.lat) as lat,
         array_agg(p.id order by p.created_at desc) as post_ids
    from public.posts p
    left join public.dong_centroids d on d.region_code = p.region_code
    left join uavg u on u.region_code = p.region_code
   where p.visibility_status = 'visible'
     and coalesce(d.lng, u.lng) is not null
     and coalesce(d.lng, u.lng) between p_min_lng and p_max_lng
     and coalesce(d.lat, u.lat) between p_min_lat and p_max_lat
   group by p.region_code, coalesce(d.lng, u.lng), coalesce(d.lat, u.lat);
$$;


--
-- Name: public_user_pets(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.public_user_pets(p_user uuid) RETURNS TABLE(id uuid, name character varying, species character varying, gender character varying, birth_date date, bio text, image_url text, identity_verified boolean, pet_match_count integer, role text, owner_name text, guardian_count integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select p.id, p.name, p.species, p.gender, p.birth_date,
         p.bio, p.image_url, p.identity_verified, p.pet_match_count,
         g.role,
         coalesce(ou.nickname, '') as owner_name,
         (select count(*)::int from public.pet_guardians gg where gg.pet_id = p.id) as guardian_count
    from public.pet_guardians g
    join public.pets p on p.id = g.pet_id and p.pet_status <> 'deleted'
    left join public.users ou on ou.id = p.primary_guardian_id
   where g.user_id = p_user
   order by (g.role = 'owner') desc, p.name;
$$;


--
-- Name: push_dispatch_batch(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.push_dispatch_batch(p_only_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50) RETURNS TABLE(notification_id uuid, ntype text, title text, body text, resource_type text, resource_id uuid, tokens jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare rec record; v_tokens jsonb;
begin
  update public.notifications set push_status='pending', updated_at=now()
   where push_status='sending' and updated_at < now() - interval '5 minutes';

  for rec in
    select n.id, n.user_id, n.notification_type::text as ntype, n.title, n.body,
           n.resource_type, n.resource_id, coalesce(n.is_silent,false) as is_silent
    from public.notifications n
    where n.push_status='pending' and (p_only_id is null or n.id = p_only_id)
    order by n.created_at
    limit p_limit
    for update of n skip locked
  loop
    if rec.is_silent then perform app.mark_push_skipped(rec.id, 'silent'); continue; end if;
    if not public._push_pref_allows(rec.user_id, rec.ntype) then
      perform app.mark_push_skipped(rec.id, 'pref_off'); continue;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('token', d.token, 'platform', d.platform)), '[]'::jsonb)
      into v_tokens from public.device_tokens d
      where d.user_id = rec.user_id and d.is_active = true;
    if v_tokens = '[]'::jsonb then perform app.mark_push_skipped(rec.id, 'no_device'); continue; end if;
    update public.notifications set push_status='sending', updated_at=now() where id = rec.id;
    notification_id := rec.id; ntype := rec.ntype; title := rec.title; body := rec.body;
    resource_type := rec.resource_type; resource_id := rec.resource_id; tokens := v_tokens;
    return next;
  end loop;
end $$;


--
-- Name: push_report(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.push_report(p_results jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare item jsonb; dead text;
begin
  for item in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    for dead in select jsonb_array_elements_text(coalesce(item->'dead_tokens', '[]'::jsonb)) loop
      perform app.deactivate_device_token(dead, 'unregistered');
    end loop;
    if coalesce((item->>'ok')::boolean, false) then
      perform app.mark_push_sent((item->>'notification_id')::uuid);
    else
      perform app.mark_push_failed((item->>'notification_id')::uuid, item->>'error', false, 3::smallint);
    end if;
  end loop;
end $$;


--
-- Name: rate_limit_hit(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_win bigint := floor(extract(epoch from now()) / greatest(p_window_seconds, 1));
  v_bucket text := p_key || ':' || v_win;
  v_count integer;
begin
  if random() < 0.02 then
    delete from app.rate_limits where expires_at < now();
  end if;
  insert into app.rate_limits(bucket, count, expires_at)
  values (v_bucket, 1, now() + make_interval(secs => p_window_seconds))
  on conflict (bucket) do update set count = app.rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_max;
end $$;


--
-- Name: record_auth_log(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_auth_log(p_user uuid, p_ip_hash text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  insert into app.auth_logs (user_id, ip_hash) values (p_user, nullif(p_ip_hash, ''));
$$;


--
-- Name: record_location_verification(uuid, numeric, numeric, integer, text, character varying, character varying, character varying, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_location_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_result text, p_region_code character varying, p_address character varying, p_fail_reason character varying, p_fail_limit integer DEFAULT 5, p_block_minutes integer DEFAULT 60) RETURNS void
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


--
-- Name: record_photo_verification(uuid, numeric, numeric, integer, character varying, boolean, character varying, numeric, numeric, numeric, numeric, boolean, character varying, text, character varying, text, text, integer, uuid, text, numeric, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_photo_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_region_code character varying, p_region_matched boolean, p_species character varying, p_dog_real numeric, p_cat_real numeric, p_dog_fake numeric, p_cat_fake numeric, p_ai_pass boolean, p_ai_reason character varying, p_result text, p_fail_reason character varying, p_image_url text, p_image_path text, p_ttl_min integer DEFAULT 15, p_pet_id uuid DEFAULT NULL::uuid, p_purpose text DEFAULT 'post'::text, p_match_score numeric DEFAULT NULL::numeric, p_matched boolean DEFAULT false, p_match_reason character varying DEFAULT NULL::character varying) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id uuid;
begin
  insert into public.photo_verifications (
    user_id, shot_lat, shot_lng, shot_accuracy_m, region_code, region_matched,
    ai_species, ai_dog_real, ai_cat_real, ai_dog_fake, ai_cat_fake, ai_pass, ai_reason,
    image_url, image_path, result, fail_reason, expires_at,
    pet_id, purpose, ai_match_score, ai_matched, ai_match_reason
  ) values (
    p_user, p_lat, p_lng, greatest(coalesce(p_accuracy, 0), 0), p_region_code, p_region_matched,
    p_species, p_dog_real, p_cat_real, p_dog_fake, p_cat_fake, p_ai_pass, p_ai_reason,
    p_image_url, p_image_path, p_result, p_fail_reason,
    now() + make_interval(mins => p_ttl_min),
    p_pet_id, coalesce(p_purpose, 'post'), p_match_score, coalesce(p_matched, false), p_match_reason
  ) returning id into v_id;
  return v_id;
end;
$$;


--
-- Name: register_device_token(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_device_token(p_token text, p_platform text, p_device_name text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_uid uuid := app.uid();
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  if p_token is null or length(p_token) < 10 then raise exception 'invalid_token' using errcode='P0001'; end if;
  insert into public.device_tokens(user_id, token, platform, device_name, is_active, failure_count, updated_at)
  values (v_uid, p_token, p_platform, p_device_name, true, 0, now())
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        device_name = coalesce(excluded.device_name, public.device_tokens.device_name),
        is_active = true, failure_count = 0, updated_at = now();
end $$;


--
-- Name: reset_password_user(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_password_user(p_phone text, p_new_hash text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id uuid;
begin
  -- 전화 인증 완료 확인(password_reset 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'password_reset'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  select id into v_id from public.users where phone = p_phone;
  if v_id is null then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  -- 비번 갱신 + 전 세션 무효화(token_version bump + refresh 전량 회수)
  update public.users
     set password_hash = p_new_hash,
         token_version = token_version + 1
   where id = v_id;
  update app.refresh_tokens set revoked_at = now()
   where user_id = v_id and revoked_at is null;

  return v_id;
end;
$$;


--
-- Name: review_owner_switch_hint(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.review_owner_switch_hint(p_review uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1
      from public.facility_reviews fr
      join public.business_profiles bp on bp.user_id = app.uid()
      join public.users u on u.id = app.uid()
     where fr.id = p_review
       and bp.status = 'approved'
       and u.active_mode = 'personal'
       and bp.matched_facility_id = any(public.facility_sibling_ids(fr.facility_id))
  );
$$;


--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


--
-- Name: rt_issue(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rt_issue(p_user uuid, p_token_hash text, p_user_agent text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_tv integer;
begin
  insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
  values (p_user, p_token_hash, gen_random_uuid(),
          now() + interval '30 days', now() + interval '90 days', p_user_agent);
  select u.token_version into v_tv from public.users u where u.id = p_user;
  return coalesce(v_tv, 0);
end $$;


--
-- Name: rt_revoke_family(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rt_revoke_family(p_hash text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update app.refresh_tokens set revoked_at = now()
   where family_id = (select family_id from app.refresh_tokens where token_hash = p_hash)
     and revoked_at is null;
$$;


--
-- Name: rt_revoke_user(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rt_revoke_user(p_user uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update app.refresh_tokens set revoked_at = now() where user_id = p_user and revoked_at is null;
$$;


--
-- Name: rt_rotate(text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rt_rotate(p_old_hash text, p_new_hash text, p_user_agent text DEFAULT NULL::text, p_grace_seconds integer DEFAULT 30) RETURNS TABLE(result text, user_id uuid, token_version integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  r app.refresh_tokens;
  s app.refresh_tokens;
  v_now timestamptz := now();
  v_aff int;
  v_tv int;
  v_new_id uuid;
begin
  select * into r from app.refresh_tokens where token_hash = p_old_hash;
  if not found then return query select 'invalid', null::uuid, null::int; return; end if;

  if not exists (select 1 from public.users u where u.id = r.user_id and u.status='active') then
    update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
      where family_id = r.family_id and revoked_at is null;
    return query select 'inactive', r.user_id, null::int; return;
  end if;
  if v_now > r.absolute_expires_at or v_now > r.expires_at then
    return query select 'expired', r.user_id, null::int; return;
  end if;

  if r.revoked_at is null then
    update app.refresh_tokens set revoked_at = v_now where id = r.id and revoked_at is null;
    get diagnostics v_aff = row_count;
    if v_aff > 0 then
      insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
      values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent);
      update app.refresh_tokens set replaced_by = (select id from app.refresh_tokens where token_hash = p_new_hash)
        where id = r.id;
      select u.token_version into v_tv from public.users u where u.id = r.user_id;
      return query select 'rotated', r.user_id, coalesce(v_tv,0); return;
    end if;
    -- v_aff=0: 동시 회전됨 → 아래 revoked 분기로
    select * into r from app.refresh_tokens where id = r.id;
  end if;

  -- 여기 도달 = 이미 revoked. ① 직후 동시요청(grace) ② 회전 응답 유실 재시도 ③ 탈취.
  --
  -- replaced_by 가 없는 revoked 토큰 = 회전이 아니라 로그아웃/패밀리 회수로 죽은 것.
  -- 이런 토큰은 grace/복구 대상이 아니다(로그아웃 직후 재사용으로 세션 부활 방지).
  if r.replaced_by is null then
    update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
      where family_id = r.family_id and revoked_at is null;
    return query select 'reuse_revoked', r.user_id, null::int; return;
  end if;

  -- ① 회전 직후 grace(동시요청·즉시 재시도) — 추가 토큰 발급.
  if v_now - r.revoked_at <= make_interval(secs => p_grace_seconds) then
    insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
    values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent);
    select u.token_version into v_tv from public.users u where u.id = r.user_id;
    return query select 'grace', r.user_id, coalesce(v_tv,0); return;
  end if;

  -- ② 유실 재시도: 후속 토큰이 한 번도 사용(회전)되지 않은 경우 — 응답을 못 받은
  --    클라이언트만 구 토큰을 다시 낼 수 있다. 미사용 후속을 회수하고 새 토큰을
  --    재발급해 세션을 복구한다(패밀리당 5회/일 제한).
  select * into s from app.refresh_tokens where id = r.replaced_by;
  if found and s.revoked_at is null and s.replaced_by is null
     and public.rate_limit_hit('rtrec:' || r.family_id::text, 5, 86400) then
    update app.refresh_tokens set revoked_at = v_now where id = s.id;
    insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
    values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent)
    returning id into v_new_id;
    update app.refresh_tokens set replaced_by = v_new_id where id = s.id;
    select u.token_version into v_tv from public.users u where u.id = r.user_id;
    return query select 'recovered', r.user_id, coalesce(v_tv,0); return;
  end if;

  -- ③ 탈취(후속이 이미 사용됨) / 복구 한도 초과 → 패밀리 전체 회수
  update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
    where family_id = r.family_id and revoked_at is null;
  return query select 'reuse_revoked', r.user_id, null::int; return;
end $$;


--
-- Name: session_alive(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.session_alive() RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$ select app.uid() is not null $$;


--
-- Name: set_activity_radius(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_activity_radius(p_m integer) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_uid uuid := app.uid(); v_verified boolean;
begin
  if v_uid is null then raise exception 'activity: 로그인이 필요합니다'; end if;
  select is_location_verified into v_verified from public.users where id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'activity: 동네 인증을 먼저 완료해주세요';
  end if;
  if p_m is null or p_m < 5000 or p_m > 15000 then
    raise exception 'activity: 활동 범위는 5~15km 사이여야 합니다';
  end if;
  update public.users set activity_radius_m = p_m where id = v_uid;
  return p_m;
end $$;


--
-- Name: set_my_business_photo(text, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_my_business_photo(p_url text DEFAULT NULL::text, p_align_y real DEFAULT 0) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_align real := greatest(-1, least(1, coalesce(p_align_y, 0)));
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  perform app.assert_business_actor();
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    photo_url = p_url, photo_align_y = v_align, updated_at = now()
  where user_id = v_me;

  if v_row.matched_facility_id is not null then
    update public.facilities set
      owner_photo_url = p_url, owner_photo_align_y = v_align,
      owner_updated_at = now(), updated_at = now()
    where id = v_row.matched_facility_id;
  end if;
end;
$$;


--
-- Name: set_pet_ai_reference(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_pet_ai_reference(p_pet uuid, p_verification uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_pv public.photo_verifications%rowtype;
begin
  select * into v_pv from public.photo_verifications
    where id = p_verification
      and pet_id = p_pet
      and purpose = 'reference'
      and result = 'pass';
  if not found then
    raise exception 'pets: 유효한 기준 사진 검증이 아닙니다';
  end if;

  update public.pets
     set ai_ref_image_url      = v_pv.image_url,
         ai_ref_image_path     = v_pv.image_path,
         ai_ref_verification_id = v_pv.id,
         ai_ref_verified_at    = now(),
         updated_at            = now()
   where id = p_pet;
end;
$$;


--
-- Name: share_view_click(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.share_view_click(p_token character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not exists (select 1 from app.share_links
                 where token = p_token and revoked_at is null and expires_at > now()) then
    return false;
  end if;
  insert into app.funnel_events (event, token) values ('store_click', p_token);
  return true;
end;
$$;


--
-- Name: share_view_load(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.share_view_load(p_token character varying) RETURNS jsonb
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
        'photo_url', bp.photo_url,
        'photo_align_y', coalesce(bp.photo_align_y, 0),
        'business_hours', bp.business_hours),
      'reviews', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'rating', r.rating, 'content', r.content,
                 'has_incentive', r.has_incentive,
                 'photo_urls', r.photos)
                 order by r.created_at desc)
        from (select rating, content, has_incentive, created_at,
                     (select coalesce(jsonb_agg(u), '[]'::jsonb)
                        from unnest(photo_urls[1:2]) u) as photos
              from public.facility_reviews
              where facility_id = f.id and visibility_status = 'visible'
              order by created_at desc limit 3) r), '[]'::jsonb))
    into v_out
    from public.facilities f
    left join lateral (
      select b.photo_url, b.photo_align_y, b.business_hours
        from public.business_profiles b
       where b.status = 'approved'
         and b.matched_facility_id = any(public.facility_sibling_ids(f.id))
       order by b.reviewed_at nulls last
       limit 1
    ) bp on true
    where f.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$$;


--
-- Name: signup_user(text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.signup_user(p_username text, p_password_hash text, p_nickname text, p_user_type text, p_phone text, p_marketing boolean DEFAULT false) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_id uuid;
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
  if exists (select 1 from public.users where phone = p_phone) then
    raise exception 'phone_taken' using errcode = 'P0001';
  end if;

  -- 3) INSERT (해시는 엣지에서 argon2id 로 생성, 필수 약관 동의 시각 기록)
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


--
-- Name: start_direct_chat(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_direct_chat(p_other uuid, p_context text DEFAULT 'personal'::text) RETURNS uuid
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


--
-- Name: switch_account_mode(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.switch_account_mode(p_mode text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_me uuid := app.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  if p_mode not in ('personal', 'business') then
    raise exception 'invalid_mode' using errcode = 'P0001';
  end if;
  if p_mode = 'business' and not exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_me and bp.status = 'approved'
  ) then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;
  update public.users set active_mode = p_mode where id = v_me;
  return p_mode;
end;
$$;


--
-- Name: update_my_business_info(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_my_business_info(p_storefront_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_hours text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_name text := nullif(btrim(coalesce(p_storefront_name, '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_email text := nullif(btrim(coalesce(p_email, '')), '');
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  perform app.assert_business_actor();
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;
  if length(coalesce(p_hours, '')) > 100 then
    raise exception 'hours_too_long' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    storefront_name = coalesce(v_name, storefront_name),
    business_phone  = coalesce(v_phone, business_phone),
    contact_email   = coalesce(v_email, contact_email),
    business_hours  = case when p_hours is null then business_hours
                           else nullif(btrim(p_hours), '') end,
    updated_at = now()
  where user_id = v_me;

  if v_row.matched_facility_id is not null
     and (v_name is not null or v_phone is not null or p_hours is not null) then
    update public.facilities set
      name = coalesce(v_name, name),
      phone = coalesce(v_phone, phone),
      business_hours = case when p_hours is null then business_hours
                            else nullif(btrim(p_hours), '') end,
      owner_updated_at = now(),
      updated_at = now()
    where id = any(public.facility_sibling_ids(v_row.matched_facility_id));
  end if;
end;
$$;


--
-- Name: update_my_post(uuid, text, text, timestamp with time zone, text, character varying, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_my_post(p_post uuid, p_title text, p_content text, p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_image_url text DEFAULT NULL::text, p_image_mime character varying DEFAULT NULL::character varying, p_image_size integer DEFAULT NULL::integer, p_edit_image boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
      when p_edit_image and v_cat in ('free', 'adoption') then p_image_url
      else image_url end,
    image_mime_type = case
      when p_edit_image and v_cat in ('free', 'adoption') then p_image_mime
      else image_mime_type end,
    image_file_size = case
      when p_edit_image and v_cat in ('free', 'adoption') then p_image_size
      else image_file_size end
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


--
-- Name: update_password_hash(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_password_hash(p_user uuid, p_old_hash text, p_new_hash text) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update public.users set password_hash = p_new_hash
  where id = p_user and password_hash = p_old_hash
  returning true;
$$;


--
-- Name: withdraw_account(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.withdraw_account() RETURNS void
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

--
-- Name: auth_logs; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.auth_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    ip_hash text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: business_doc_purge_queue; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.business_doc_purge_queue (
    id bigint NOT NULL,
    path text NOT NULL,
    reason text NOT NULL,
    purge_after timestamp with time zone NOT NULL,
    purged_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: business_doc_purge_queue_id_seq; Type: SEQUENCE; Schema: app; Owner: -
--

ALTER TABLE app.business_doc_purge_queue ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME app.business_doc_purge_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: business_licenses; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.business_licenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    license_type app.biz_license_type NOT NULL,
    license_no character varying(40) NOT NULL,
    document_path text NOT NULL,
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    reject_reason text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_licenses_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying])::text[])))
);


--
-- Name: TABLE business_licenses; Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON TABLE app.business_licenses IS '업종별 등록·허가 증빙(0028 §1). approved 행 존재 = 해당 업종 모듈 ON(app.has_license).';


--
-- Name: business_purge_config; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.business_purge_config (
    id boolean DEFAULT true NOT NULL,
    function_url text NOT NULL,
    trigger_secret text DEFAULT encode(extensions.gen_random_bytes(24), 'hex'::text) NOT NULL,
    CONSTRAINT business_purge_config_singleton CHECK (id)
);


--
-- Name: funnel_events; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.funnel_events (
    id bigint NOT NULL,
    event character varying(30) NOT NULL,
    token character varying(32),
    user_id uuid,
    props jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE funnel_events; Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON TABLE app.funnel_events IS '오프라인 제휴 파일럿 퍼널 계측(0028 §7). 원시 이벤트 보존 1년.';


--
-- Name: funnel_events_id_seq; Type: SEQUENCE; Schema: app; Owner: -
--

ALTER TABLE app.funnel_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME app.funnel_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: location_usage_logs; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.location_usage_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    purpose text NOT NULL,
    provided_to text,
    used_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE location_usage_logs; Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON TABLE app.location_usage_logs IS '위치정보 이용·제공사실 확인자료 (위치정보법 제16조 제2항, 6개월 보존 후 파기)';


--
-- Name: push_config; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.push_config (
    id boolean DEFAULT true NOT NULL,
    function_url text NOT NULL,
    trigger_secret text DEFAULT encode(extensions.gen_random_bytes(24), 'hex'::text) NOT NULL,
    CONSTRAINT push_config_singleton CHECK (id)
);


--
-- Name: rate_limits; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.rate_limits (
    bucket text NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: refresh_tokens; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.refresh_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    family_id uuid NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    absolute_expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    replaced_by uuid,
    user_agent text
);


--
-- Name: share_links; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.share_links (
    token character varying(32) NOT NULL,
    kind character varying(20) NOT NULL,
    ref_id uuid NOT NULL,
    created_by uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    view_count integer DEFAULT 0 NOT NULL,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT share_links_kind_check CHECK (((kind)::text = ANY ((ARRAY['facility_preview'::character varying, 'care_report'::character varying])::text[])))
);


--
-- Name: TABLE share_links; Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON TABLE app.share_links IS '설치 전 가치 전달용 공유 링크(0028 §3). share-view Edge Function 이 서빙.';


--
-- Name: withdrawn_users; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.withdrawn_users (
    user_id uuid NOT NULL,
    username text,
    phone text,
    withdrawn_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: admin_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    admin_id uuid,
    action_type character varying(50) NOT NULL,
    target_type character varying(20),
    target_id uuid,
    detail jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    applicant_id uuid NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    offered_pet_id uuid,
    CONSTRAINT applications_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'rejected'::character varying, 'cancelled'::character varying, 'completed'::character varying])::text[])))
);


--
-- Name: TABLE applications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.applications IS '게시글 지원. UNIQUE(post_id, applicant_id) 풀제약 → 한 게시글에 한 사용자는 1회만(취소·거절 후에도 재지원 불가). 정책 변경 시 partial unique 로 전환 필요.';


--
-- Name: COLUMN applications.offered_pet_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.applications.offered_pet_id IS '입양 글 지원 시 지원자가 넘길 반려동물. 비입양 글에선 NULL';


--
-- Name: appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    application_id uuid NOT NULL,
    post_id uuid NOT NULL,
    post_owner_id uuid NOT NULL,
    applicant_id uuid NOT NULL,
    status character varying(20) DEFAULT 'scheduled'::character varying NOT NULL,
    scheduled_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    trust_awarded boolean DEFAULT false NOT NULL,
    CONSTRAINT appointments_completed_at_chk CHECK ((((status)::text <> 'completed'::text) OR (completed_at IS NOT NULL))),
    CONSTRAINT appointments_participants_distinct CHECK ((post_owner_id <> applicant_id)),
    CONSTRAINT appointments_status_check CHECK (((status)::text = ANY ((ARRAY['scheduled'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: business_match_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_match_rules (
    rule_key character varying NOT NULL,
    weight integer NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    params jsonb,
    note text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: business_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_profiles (
    user_id uuid NOT NULL,
    business_reg_no character varying(10) NOT NULL,
    declared_category character varying(20) NOT NULL,
    business_name text NOT NULL,
    storefront_name text,
    prev_business_name text,
    business_address text NOT NULL,
    business_address_jibun text,
    business_region_code character varying(20),
    business_phone character varying(40),
    representative_name text,
    contact_email text NOT NULL,
    license_image_path text NOT NULL,
    extra_doc_path text,
    nts_status_code character varying(2),
    nts_checked_at timestamp with time zone,
    matched_facility_id uuid,
    matched_biz_key text,
    match_score integer,
    match_detail jsonb,
    review_track character varying DEFAULT 'review'::character varying NOT NULL,
    auto_approved boolean DEFAULT false NOT NULL,
    review_note text,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    rejected_reason text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    photo_url text,
    photo_align_y real DEFAULT 0 NOT NULL,
    business_hours character varying(100),
    CONSTRAINT business_profiles_business_reg_no_check CHECK (((business_reg_no)::text ~ '^\d{10}$'::text)),
    CONSTRAINT business_profiles_contact_email_check CHECK ((contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text)),
    CONSTRAINT business_profiles_declared_category_check CHECK (((declared_category)::text = ANY ((ARRAY['pet_sales'::character varying, 'pet_hotel'::character varying, 'animal_hospital'::character varying, 'grooming'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT business_profiles_review_track_check CHECK (((review_track)::text = ANY ((ARRAY['auto'::character varying, 'review'::character varying, 'new_business'::character varying])::text[]))),
    CONSTRAINT business_profiles_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying])::text[])))
);


--
-- Name: TABLE business_profiles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.business_profiles IS '업체(사업자) 인증 프로필 — users 와 1:1, 쓰기는 definer RPC 전용 (0025).';


--
-- Name: chat_message_deletions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_message_deletions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid NOT NULL,
    user_id uuid NOT NULL,
    deleted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    room_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    content text,
    image_url text,
    image_thumbnail_url text,
    image_mime_type character varying(50),
    image_file_size integer,
    image_width smallint,
    image_height smallint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT chat_messages_content_not_blank CHECK (((content IS NULL) OR (length(TRIM(BOTH FROM content)) > 0))),
    CONSTRAINT chat_messages_image_file_size_check CHECK (((image_file_size IS NULL) OR (image_file_size <= 10485760))),
    CONSTRAINT chat_messages_not_empty CHECK (((content IS NOT NULL) OR (image_url IS NOT NULL)))
);


--
-- Name: chat_room_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_room_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    room_id uuid NOT NULL,
    user_id uuid NOT NULL,
    last_read_message_id uuid,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    left_at timestamp with time zone
);


--
-- Name: chat_rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_rooms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    room_type character varying(20) DEFAULT 'direct'::character varying NOT NULL,
    canonical_key character varying(160) NOT NULL,
    last_message_id uuid,
    last_message_at timestamp with time zone,
    last_message_preview character varying(100),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    context character varying DEFAULT 'personal'::character varying NOT NULL,
    business_user_id uuid,
    CONSTRAINT chat_rooms_context_check CHECK (((context)::text = ANY ((ARRAY['personal'::character varying, 'business'::character varying])::text[]))),
    CONSTRAINT chat_rooms_room_type_check CHECK (((room_type)::text = ANY ((ARRAY['direct'::character varying, 'admin_inquiry'::character varying])::text[])))
);


--
-- Name: comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    user_id uuid NOT NULL,
    content text NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    authored_as character varying DEFAULT 'personal'::character varying NOT NULL,
    CONSTRAINT comments_authored_as_check CHECK (((authored_as)::text = ANY ((ARRAY['personal'::character varying, 'business'::character varying])::text[])))
);


--
-- Name: device_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token text NOT NULL,
    platform character varying(10) NOT NULL,
    device_name character varying(100),
    is_active boolean DEFAULT true NOT NULL,
    failure_count smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT device_tokens_failure_count_check CHECK ((failure_count >= 0)),
    CONSTRAINT device_tokens_platform_check CHECK (((platform)::text = ANY ((ARRAY['ios'::character varying, 'android'::character varying])::text[])))
);


--
-- Name: dong_centroids; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dong_centroids (
    region_code character varying(20) NOT NULL,
    name text,
    lng double precision NOT NULL,
    lat double precision NOT NULL,
    source character varying(20) DEFAULT 'geocode'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: facilities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facilities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category public.facility_category NOT NULL,
    source character varying(30) NOT NULL,
    ext_id character varying(160) NOT NULL,
    name character varying(200) NOT NULL,
    address text,
    phone character varying(40),
    biz_status character varying(20),
    is_open boolean DEFAULT true NOT NULL,
    license_date date,
    region_code character varying(20),
    geom public.geography(Point,4326),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    avg_rating numeric(2,1) DEFAULT 0 NOT NULL,
    review_count integer DEFAULT 0 NOT NULL,
    owner_updated_at timestamp with time zone,
    owner_photo_url text,
    owner_photo_align_y real DEFAULT 0 NOT NULL,
    business_hours character varying(100)
);


--
-- Name: TABLE facilities; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.facilities IS '공공데이터 반려동물 시설(병원/미용/위탁/판매). geom=WGS84(4326). 적재시 좌표 사전변환됨 (0021).';


--
-- Name: facility_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facility_cache (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kakao_place_id character varying(50) NOT NULL,
    source_provider character varying(20) DEFAULT 'kakao'::character varying NOT NULL,
    name character varying(100) NOT NULL,
    category character varying(30) NOT NULL,
    address text,
    lat numeric(10,7) NOT NULL,
    lng numeric(10,7) NOT NULL,
    phone character varying(20),
    website_url text,
    business_hours jsonb,
    thumbnail_url text,
    is_open_now boolean,
    open_status_updated_at timestamp with time zone,
    cached_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    last_api_sync_at timestamp with time zone,
    sync_fail_count smallint DEFAULT 0 NOT NULL,
    CONSTRAINT facility_cache_source_provider_check CHECK (((source_provider)::text = ANY ((ARRAY['kakao'::character varying, 'naver'::character varying, 'google'::character varying])::text[]))),
    CONSTRAINT facility_cache_sync_fail_count_check CHECK ((sync_fail_count >= 0))
);


--
-- Name: facility_review_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facility_review_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    review_id uuid NOT NULL,
    user_id uuid NOT NULL,
    content text NOT NULL,
    authored_as character varying DEFAULT 'personal'::character varying NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT facility_review_comments_authored_as_check CHECK (((authored_as)::text = ANY ((ARRAY['personal'::character varying, 'business'::character varying])::text[]))),
    CONSTRAINT frc_content_len CHECK (((length(btrim(content)) >= 1) AND (length(btrim(content)) <= 1000)))
);


--
-- Name: facility_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facility_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    facility_id uuid NOT NULL,
    user_id uuid NOT NULL,
    rating smallint NOT NULL,
    content text,
    photo_urls text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    photo_paths text[] DEFAULT '{}'::text[] NOT NULL,
    visibility_status character varying(20) DEFAULT 'visible'::character varying NOT NULL,
    has_incentive boolean DEFAULT false NOT NULL,
    CONSTRAINT facility_reviews_photos_max CHECK (((array_length(photo_paths, 1) IS NULL) OR (array_length(photo_paths, 1) <= 5))),
    CONSTRAINT facility_reviews_rating_check CHECK (((rating >= 1) AND (rating <= 5)))
);


--
-- Name: COLUMN facility_reviews.has_incentive; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.facility_reviews.has_incentive IS '업체로부터 할인·사은품 등 혜택을 받고 작성 — 표시광고법 표시 의무(0028 §6)';


--
-- Name: location_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.location_verifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    verified_lat numeric(10,7) NOT NULL,
    verified_lng numeric(10,7) NOT NULL,
    verified_radius_meters smallint NOT NULL,
    result character varying(20) NOT NULL,
    fail_reason character varying(50),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT location_verifications_result_check CHECK (((result)::text = ANY ((ARRAY['success'::character varying, 'failed'::character varying, 'blocked'::character varying])::text[])))
);


--
-- Name: notification_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    chat_message boolean DEFAULT true,
    post_application boolean DEFAULT true,
    post_comment boolean DEFAULT true,
    pawing_new_post boolean DEFAULT true,
    application_accepted boolean DEFAULT true,
    review_received boolean DEFAULT true,
    system_notice boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    actor_user_id uuid,
    notification_type character varying(50) NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    priority character varying(10) DEFAULT 'normal'::character varying NOT NULL,
    is_silent boolean DEFAULT false NOT NULL,
    notification_group_key character varying(100),
    title text,
    body text,
    aggregated_count integer DEFAULT 1 NOT NULL,
    resource_type character varying(30),
    resource_id uuid,
    is_read boolean DEFAULT false NOT NULL,
    read_at timestamp with time zone,
    push_sent boolean,
    push_sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    push_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    push_attempts smallint DEFAULT 0 NOT NULL,
    push_error text,
    CONSTRAINT notifications_aggregated_count_check CHECK ((aggregated_count >= 1)),
    CONSTRAINT notifications_notification_type_check CHECK (((notification_type)::text = ANY (ARRAY['chat_message'::text, 'post_application'::text, 'post_comment'::text, 'pawing_new_post'::text, 'application_accepted'::text, 'application_accepted_by_co'::text, 'review_received'::text, 'guardian_invite'::text, 'system_notice'::text, 'location_expired'::text, 'chat_read_receipt'::text, 'unread_sync'::text, 'security_login'::text, 'schedule_changed'::text, 'business_approved'::text, 'business_rejected'::text, 'review_comment'::text, 'post_heart'::text, 'pawing_follow'::text, 'facility_review_received'::text, 'pet_in_post'::text]))),
    CONSTRAINT notifications_priority_check CHECK (((priority)::text = ANY ((ARRAY['high'::character varying, 'normal'::character varying, 'low'::character varying])::text[]))),
    CONSTRAINT notifications_push_attempts_check CHECK ((push_attempts >= 0)),
    CONSTRAINT notifications_push_status_check CHECK (((push_status)::text = ANY (ARRAY['pending'::text, 'sending'::text, 'sent'::text, 'failed'::text, 'skipped'::text]))),
    CONSTRAINT notifications_resource_type_check CHECK (((resource_type IS NULL) OR ((resource_type)::text = ANY (ARRAY['post'::text, 'comment'::text, 'chat_room'::text, 'appointment'::text, 'facility_review'::text, 'user'::text]))))
);


--
-- Name: COLUMN notifications.aggregated_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notifications.aggregated_count IS '병합된 이벤트 수. INSERT ON CONFLICT DO UPDATE 의 행락(row lock)으로 race-safe. 절대 시점 정확성이 아니라 결국정확(eventual consistency) 모델';


--
-- Name: COLUMN notifications.push_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notifications.push_status IS '푸시 발송 상태. pending=미발송/재시도대기, sent=성공, failed=영구실패(임계 초과), skipped=조건상 미발송(사용자 설정/토큰없음 등). 권장 흐름: Database Webhook → Edge Function 이 갱신';


--
-- Name: COLUMN notifications.push_attempts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notifications.push_attempts IS '푸시 발송 시도 횟수. mark_push_failed 호출 시 임계치(기본 3회) 초과하면 push_status=failed 로 자동 전환';


--
-- Name: COLUMN notifications.push_error; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.notifications.push_error IS '마지막 푸시 실패 사유 텍스트(디버그/모니터링용)';


--
-- Name: pawings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pawings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    follower_id uuid NOT NULL,
    following_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notified boolean DEFAULT false NOT NULL,
    context character varying DEFAULT 'personal'::character varying NOT NULL,
    CONSTRAINT pawings_context_check CHECK (((context)::text = ANY ((ARRAY['personal'::character varying, 'business'::character varying])::text[]))),
    CONSTRAINT pawings_self_chk CHECK ((follower_id <> following_id))
);


--
-- Name: TABLE pawings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pawings IS '팔로우(Pawing). 언팔로우 = 하드 DELETE(soft delete 사용 안 함). UNIQUE(follower_id, following_id) 재생성 자유.';


--
-- Name: pet_guardian_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pet_guardian_invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pet_id uuid NOT NULL,
    kind character varying(10) NOT NULL,
    inviter_id uuid NOT NULL,
    invitee_phone character varying(20),
    invitee_user_id uuid,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    responded_at timestamp with time zone,
    CONSTRAINT pet_guardian_invites_kind_check CHECK (((kind)::text = ANY ((ARRAY['invite'::character varying, 'request'::character varying])::text[]))),
    CONSTRAINT pet_guardian_invites_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'expired'::character varying])::text[])))
);


--
-- Name: TABLE pet_guardian_invites; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pet_guardian_invites IS '공동보호자 초대/요청. UNIQUE 는 status=pending 한정 partial → 거절/만료 후 재초대 가능.';


--
-- Name: pet_guardians; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pet_guardians (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pet_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(20) DEFAULT 'co_guardian'::character varying NOT NULL,
    invited_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pet_guardians_role_check CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'co_guardian'::character varying])::text[])))
);


--
-- Name: pet_identity_frames; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pet_identity_frames (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pet_id uuid NOT NULL,
    frame_index smallint NOT NULL,
    image_url text NOT NULL,
    image_path text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE pet_identity_frames; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pet_identity_frames IS '펫 등록 영상에서 추출한 기준 프레임. 게시글 사진 동일개체 매칭에 사용 (0020).';


--
-- Name: pets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    primary_guardian_id uuid NOT NULL,
    name character varying(50) NOT NULL,
    species character varying(50) NOT NULL,
    gender character varying(10),
    birth_date date,
    is_neutered boolean DEFAULT false NOT NULL,
    image_url text,
    image_thumbnail_url text,
    image_mime_type character varying(50),
    image_file_size integer,
    image_width smallint,
    image_height smallint,
    bio text,
    pet_status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    ai_ref_image_url text,
    ai_ref_image_path text,
    ai_ref_verification_id uuid,
    ai_ref_verified_at timestamp with time zone,
    pet_match_count integer DEFAULT 0 NOT NULL,
    species_kind character varying(10),
    identity_verified boolean DEFAULT false NOT NULL,
    identity_verified_at timestamp with time zone,
    ai_species character varying(10),
    ai_breed character varying(50),
    ai_colors text[],
    info_match jsonb,
    trust_score integer DEFAULT 0 NOT NULL,
    CONSTRAINT pets_gender_check CHECK (((gender IS NULL) OR ((gender)::text = ANY ((ARRAY['male'::character varying, 'female'::character varying])::text[])))),
    CONSTRAINT pets_pet_status_check CHECK (((pet_status)::text = ANY ((ARRAY['active'::character varying, 'transferred'::character varying, 'deceased'::character varying, 'deleted'::character varying])::text[]))),
    CONSTRAINT pets_species_kind_check CHECK (((species_kind IS NULL) OR ((species_kind)::text = ANY ((ARRAY['dog'::character varying, 'cat'::character varying])::text[]))))
);


--
-- Name: TABLE pets; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pets IS 'pet_status 로 soft delete. 과거 게시글·평가 FK 참조 보존';


--
-- Name: COLUMN pets.primary_guardian_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.primary_guardian_id IS '현재 소유자(owner) user_id. 소유권 이전 시 이 값 변경. 전체 보호자는 pet_guardians 참조';


--
-- Name: COLUMN pets.ai_ref_image_path; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.ai_ref_image_path IS 'AI 인증 기준 사진의 media 경로(개체 대조 baseline). 대표사진 image_url 과 별개 (0019)';


--
-- Name: COLUMN pets.pet_match_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.pet_match_count IS '검증 카테고리 게시글에서 개체 일치가 누적된 횟수(펫 신뢰도) (0019)';


--
-- Name: COLUMN pets.species_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.species_kind IS '종 분류 강아지(dog)/고양이(cat). species 는 품종 자유텍스트.';


--
-- Name: COLUMN pets.identity_verified; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.identity_verified IS '신원 영상 인증(기준 프레임 등록) 완료 여부. 게시글 사진 매칭의 전제 (0020).';


--
-- Name: COLUMN pets.info_match; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.info_match IS '등록정보 대조 결과. 예: {"species_kind":true,"breed":false,"color":false,"warnings":["breed"]}.';


--
-- Name: phone_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phone_verifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    phone character varying(20) NOT NULL,
    code character varying(10) NOT NULL,
    purpose character varying(20) DEFAULT 'signup'::character varying NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    is_used boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phone_verifications_purpose_check CHECK (((purpose)::text = ANY ((ARRAY['signup'::character varying, 'password_reset'::character varying])::text[])))
);


--
-- Name: TABLE phone_verifications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.phone_verifications IS '전화 인증/비번재설정 코드(6자리·5분). rate limit: 동일 번호 1분당 1회(서비스/엣지)';


--
-- Name: photo_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.photo_verifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    shot_lat numeric(10,7),
    shot_lng numeric(10,7),
    shot_accuracy_m smallint,
    region_code character varying(20),
    region_matched boolean DEFAULT false NOT NULL,
    ai_species character varying(10),
    ai_dog_real numeric(4,3) DEFAULT 0 NOT NULL,
    ai_cat_real numeric(4,3) DEFAULT 0 NOT NULL,
    ai_dog_fake numeric(4,3) DEFAULT 0 NOT NULL,
    ai_cat_fake numeric(4,3) DEFAULT 0 NOT NULL,
    ai_pass boolean DEFAULT false NOT NULL,
    ai_reason character varying(200),
    image_url text,
    image_path text,
    result character varying(10) NOT NULL,
    fail_reason character varying(40),
    consumed_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    pet_id uuid,
    purpose character varying(20) DEFAULT 'post'::character varying NOT NULL,
    ai_match_score numeric(4,3),
    ai_matched boolean DEFAULT false NOT NULL,
    ai_match_reason character varying(200),
    CONSTRAINT photo_verifications_purpose_check CHECK (((purpose)::text = ANY (ARRAY['reference'::text, 'post'::text, 'pet_identity'::text]))),
    CONSTRAINT photo_verifications_result_check CHECK (((result)::text = ANY ((ARRAY['pass'::character varying, 'fail'::character varying])::text[])))
);


--
-- Name: TABLE photo_verifications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.photo_verifications IS '게시글 사진 실존 검증(촬영 위치 일치 + AI 반려동물 판별) 로그 및 1회용 토큰 (0018)';


--
-- Name: post_hearts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_hearts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notified boolean DEFAULT false NOT NULL
);


--
-- Name: TABLE post_hearts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.post_hearts IS '하트(관심 게시글/북마크). 요구사항 F-27. 토글 = 하드 DELETE(soft delete 사용 안 함). UNIQUE(post_id, user_id) → 재생성 자유. ※ 좋아요(like) 와는 별개 개념 — 좋아요는 초기 단계에 제거되어 평가 시스템으로 흡수됨';


--
-- Name: post_pets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_pets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    pet_id uuid NOT NULL
);


--
-- Name: post_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_views (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    user_id uuid,
    ip_hash character varying(64),
    session_id character varying(100),
    view_bucket timestamp with time zone NOT NULL,
    viewed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT post_views_identity_chk CHECK (((user_id IS NOT NULL) OR (ip_hash IS NOT NULL)))
);


--
-- Name: posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    category character varying(20) NOT NULL,
    title character varying(200) NOT NULL,
    content text NOT NULL,
    image_url text,
    image_thumbnail_url text,
    image_mime_type character varying(50),
    image_file_size integer,
    image_width smallint,
    image_height smallint,
    scheduled_at timestamp with time zone,
    visibility_status character varying(30) DEFAULT 'visible'::character varying NOT NULL,
    progress_status character varying(20) DEFAULT 'recruiting'::character varying NOT NULL,
    deleted_at timestamp with time zone,
    view_count integer DEFAULT 0 NOT NULL,
    heart_count integer DEFAULT 0 NOT NULL,
    comment_count integer DEFAULT 0 NOT NULL,
    actual_lat numeric(10,7),
    actual_lng numeric(10,7),
    display_lat numeric(8,5),
    display_lng numeric(8,5),
    display_address character varying(100),
    region_code character varying(20),
    location_radius_m smallint,
    is_location_hidden boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    photo_verification_id uuid,
    ai_pet_species character varying(10),
    is_pet_verified boolean DEFAULT false NOT NULL,
    edited_at timestamp with time zone,
    authored_as character varying DEFAULT 'personal'::character varying NOT NULL,
    pawing_notified boolean DEFAULT false NOT NULL,
    CONSTRAINT posts_authored_as_check CHECK (((authored_as)::text = ANY ((ARRAY['personal'::character varying, 'business'::character varying])::text[]))),
    CONSTRAINT posts_category_check CHECK (((category)::text = ANY (ARRAY['walk_together'::text, 'walk_proxy'::text, 'care'::text, 'adoption'::text, 'give_away'::text, 'free'::text, 'news'::text]))),
    CONSTRAINT posts_comment_count_check CHECK ((comment_count >= 0)),
    CONSTRAINT posts_deleted_at_consistency CHECK ((((visibility_status)::text !~~ 'deleted_%'::text) OR (deleted_at IS NOT NULL))),
    CONSTRAINT posts_image_file_size_check CHECK (((image_file_size IS NULL) OR (image_file_size <= 12582912))),
    CONSTRAINT posts_like_count_check CHECK ((heart_count >= 0)),
    CONSTRAINT posts_progress_status_check CHECK (((progress_status)::text = ANY ((ARRAY['recruiting'::character varying, 'matched'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[]))),
    CONSTRAINT posts_view_count_check CHECK ((view_count >= 0)),
    CONSTRAINT posts_visibility_status_check CHECK (((visibility_status)::text = ANY ((ARRAY['visible'::character varying, 'hidden_by_user'::character varying, 'hidden_by_admin'::character varying, 'deleted_by_user'::character varying, 'deleted_by_admin'::character varying])::text[])))
);


--
-- Name: COLUMN posts.heart_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.posts.heart_count IS '하트 누적 캐시. tg_post_hearts_count 트리거가 INSERT/DELETE 시 ±1 자동 동기화';


--
-- Name: COLUMN posts.actual_lat; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.posts.actual_lat IS '실제 좌표(서버 내부 연산 전용, API 응답 제외)';


--
-- Name: COLUMN posts.display_lat; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.posts.display_lat IS '공개 좌표(50~200m 랜덤 offset). is_location_hidden=true 면 클라이언트 미전송';


--
-- Name: COLUMN posts.is_pet_verified; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.posts.is_pet_verified IS '서버 검증(촬영위치 일치 + AI 실제 반려동물) 통과 사진으로 작성된 글 (0018)';


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    appointment_id uuid NOT NULL,
    reviewer_id uuid NOT NULL,
    reviewee_id uuid NOT NULL,
    categories text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reviews_allowed_chk CHECK ((categories <@ ARRAY['친절해요'::text, '약속을잘지켜요'::text, '반려동물이순해요'::text, '준비성이좋아요'::text, '불친절해요'::text, '약속을잘안지켜요'::text, '반려동물이사나워요'::text, '준비성이아쉬워요'::text])),
    CONSTRAINT reviews_excl_kind CHECK ((NOT (('친절해요'::text = ANY (categories)) AND ('불친절해요'::text = ANY (categories))))),
    CONSTRAINT reviews_excl_prepared CHECK ((NOT (('준비성이좋아요'::text = ANY (categories)) AND ('준비성이아쉬워요'::text = ANY (categories))))),
    CONSTRAINT reviews_excl_promise CHECK ((NOT (('약속을잘지켜요'::text = ANY (categories)) AND ('약속을잘안지켜요'::text = ANY (categories))))),
    CONSTRAINT reviews_excl_temper CHECK ((NOT (('반려동물이순해요'::text = ANY (categories)) AND ('반려동물이사나워요'::text = ANY (categories))))),
    CONSTRAINT reviews_len_chk CHECK (((array_length(categories, 1) >= 1) AND (array_length(categories, 1) <= 4))),
    CONSTRAINT reviews_self_chk CHECK ((reviewer_id <> reviewee_id))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    username character varying(50) NOT NULL,
    password_hash text NOT NULL,
    nickname character varying(50) NOT NULL,
    user_type character varying(20) NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    address character varying(100),
    latitude numeric(10,7),
    longitude numeric(10,7),
    is_location_verified boolean DEFAULT false NOT NULL,
    last_verified_at timestamp with time zone,
    profile_image_url text,
    profile_image_thumbnail_url text,
    profile_image_mime_type character varying(50),
    profile_image_file_size integer,
    push_enabled boolean DEFAULT true NOT NULL,
    unread_notification_count integer DEFAULT 0 NOT NULL,
    unread_chat_count integer DEFAULT 0 NOT NULL,
    location_verify_fail_count smallint DEFAULT 0 NOT NULL,
    location_verify_blocked_until timestamp with time zone,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    phone character varying(20),
    phone_verified boolean DEFAULT false NOT NULL,
    region_code character varying(20),
    activity_radius_m smallint,
    token_version integer DEFAULT 0 NOT NULL,
    terms_agreed_at timestamp with time zone,
    marketing_opt_in boolean DEFAULT false NOT NULL,
    marketing_opt_in_at timestamp with time zone,
    active_mode character varying DEFAULT 'personal'::character varying NOT NULL,
    CONSTRAINT users_active_mode_check CHECK (((active_mode)::text = ANY ((ARRAY['personal'::character varying, 'business'::character varying])::text[]))),
    CONSTRAINT users_activity_radius_chk CHECK (((activity_radius_m IS NULL) OR ((activity_radius_m >= 5000) AND (activity_radius_m <= 15000)))),
    CONSTRAINT users_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying, 'suspended'::character varying, 'deleted'::character varying])::text[]))),
    CONSTRAINT users_unread_chat_count_nonneg CHECK ((unread_chat_count >= 0)),
    CONSTRAINT users_unread_notification_count_nonneg CHECK ((unread_notification_count >= 0)),
    CONSTRAINT users_user_type_check CHECK (((user_type)::text = ANY ((ARRAY['pet_owner'::character varying, 'no_pet'::character varying, 'business'::character varying, 'admin'::character varying])::text[]))),
    CONSTRAINT users_verify_fail_count_nonneg CHECK ((location_verify_fail_count >= 0))
);


--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.users IS '사용자(커스텀 인증). password_hash 노출 금지 → 외부는 public_profiles 뷰 조회';


--
-- Name: COLUMN users.unread_notification_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.unread_notification_count IS 'DB source of truth (트리거 자동 갱신). 앱에서 직접 수정 금지';


--
-- Name: COLUMN users.unread_chat_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.unread_chat_count IS 'DB source of truth (트리거 자동 갱신). 앱에서 직접 수정 금지';


--
-- Name: COLUMN users.phone; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.phone IS '인증된 전화번호(신원/공동보호자 초대 매칭 키). PII → 컬럼 GRANT 미부여로 클라이언트 비공개';


--
-- Name: COLUMN users.region_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.region_code IS '인증된 활동 지역의 행정동코드(Naver admcode, 10자리). is_location_verified=true 일 때 채워짐';


--
-- Name: public_profiles; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.public_profiles AS
 SELECT u.id,
    u.nickname,
    u.user_type,
    u.profile_image_url,
    u.profile_image_thumbnail_url,
    u.address,
    u.is_location_verified,
    u.created_at,
    u.activity_radius_m,
    COALESCE(((bp.status)::text = 'approved'::text), false) AS is_business,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.business_name
            ELSE NULL::text
        END AS business_name,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.declared_category
            ELSE NULL::character varying
        END AS business_category,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.business_address
            ELSE NULL::text
        END AS business_address,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.business_phone
            ELSE NULL::character varying
        END AS business_phone,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.matched_facility_id
            ELSE NULL::uuid
        END AS business_facility_id,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.photo_url
            ELSE NULL::text
        END AS business_photo_url,
        CASE
            WHEN ((bp.status)::text = 'approved'::text) THEN bp.business_hours
            ELSE NULL::character varying
        END AS business_hours,
    (( SELECT count(*) AS count
           FROM public.reviews r
          WHERE (r.reviewee_id = u.id)))::integer AS review_count,
    (( SELECT count(*) AS count
           FROM public.pawings p
          WHERE ((p.follower_id = u.id) AND ((p.context)::text = 'personal'::text))))::integer AS pawing_count,
    (( SELECT count(*) AS count
           FROM public.pawings p
          WHERE ((p.following_id = u.id) AND ((p.context)::text = 'personal'::text))))::integer AS pawmate_count
   FROM (public.users u
     LEFT JOIN public.business_profiles bp ON ((bp.user_id = u.id)));


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reporter_id uuid NOT NULL,
    target_type character varying(20) NOT NULL,
    target_id uuid NOT NULL,
    categories text[] NOT NULL,
    extra_description text,
    status character varying(20) DEFAULT 'submitted'::character varying NOT NULL,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT reports_categories_allowed CHECK ((categories <@ ARRAY['욕설비방'::text, '허위정보'::text, '사기의심'::text, '부적절한내용'::text, '약속불이행'::text, '기타'::text, '카테고리와 무관해요'::text, '실제 반려동물이 아니에요'::text, '기타(직접작성)'::text])),
    CONSTRAINT reports_categories_len CHECK ((array_length(categories, 1) >= 1)),
    CONSTRAINT reports_extra_required CHECK (((NOT (('기타'::text = ANY (categories)) OR ('기타(직접작성)'::text = ANY (categories)))) OR ((extra_description IS NOT NULL) AND (length(btrim(extra_description)) > 0)))),
    CONSTRAINT reports_status_check CHECK (((status)::text = ANY ((ARRAY['submitted'::character varying, 'reviewing'::character varying, 'resolved'::character varying, 'dismissed'::character varying])::text[]))),
    CONSTRAINT reports_target_type_check CHECK (((target_type)::text = ANY ((ARRAY['post'::character varying, 'comment'::character varying, 'chat_message'::character varying, 'user'::character varying])::text[])))
);


--
-- Name: TABLE reports; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.reports IS '신고. target 은 polymorphic 이며 FK 없음. 대상이 삭제되더라도 신고 행은 감사 기록으로 보존(cascade 없음, orphan 허용).';


--
-- Name: review_category_counts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.review_category_counts (
    user_id uuid NOT NULL,
    category character varying(50) NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT review_category_counts_count_check CHECK ((count >= 0))
);


--
-- Name: user_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_blocks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    blocker_id uuid NOT NULL,
    blocked_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_blocks_self_chk CHECK ((blocker_id <> blocked_id))
);


--
-- Name: v_chat_rooms; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_chat_rooms AS
 SELECT r.id,
    r.last_message_preview,
    r.last_message_at,
    COALESCE(( SELECT
                CASE
                    WHEN (((r.context)::text = 'business'::text) AND (m2.user_id = r.business_user_id)) THEN COALESCE(bp.business_name, (pr.nickname)::text)
                    ELSE (pr.nickname)::text
                END AS nickname
           FROM (((public.chat_room_members m2
             JOIN public.public_profiles pr ON ((pr.id = m2.user_id)))
             JOIN public.users u2 ON ((u2.id = m2.user_id)))
             LEFT JOIN public.business_profiles bp ON (((bp.user_id = m2.user_id) AND ((bp.status)::text = 'approved'::text))))
          WHERE ((m2.room_id = r.id) AND (m2.user_id <> app.uid()) AND (((r.room_type)::text <> 'admin_inquiry'::text) OR ((u2.user_type)::text <> 'admin'::text)))
         LIMIT 1),
        CASE
            WHEN ((r.room_type)::text = 'admin_inquiry'::text) THEN '고객센터'::text
            ELSE '알 수 없음'::text
        END) AS other_nickname,
    ( SELECT m2.user_id
           FROM (public.chat_room_members m2
             JOIN public.users u2 ON ((u2.id = m2.user_id)))
          WHERE ((m2.room_id = r.id) AND (m2.user_id <> app.uid()) AND (((r.room_type)::text <> 'admin_inquiry'::text) OR ((u2.user_type)::text <> 'admin'::text)))
         LIMIT 1) AS other_user_id,
    ( SELECT count(*) AS count
           FROM public.chat_messages cm
          WHERE ((cm.room_id = r.id) AND (cm.is_deleted = false) AND (cm.sender_id <> app.uid()) AND ((m.last_read_message_id IS NULL) OR (cm.created_at > ( SELECT lr.created_at
                   FROM public.chat_messages lr
                  WHERE (lr.id = m.last_read_message_id)))))) AS unread_count,
    (EXISTS ( SELECT 1
           FROM public.chat_room_members m3
          WHERE ((m3.room_id = r.id) AND (m3.user_id <> app.uid()) AND (m3.left_at IS NOT NULL)))) AS other_left,
    ( SELECT
                CASE
                    WHEN (((r.context)::text = 'business'::text) AND (m2.user_id = r.business_user_id)) THEN bp.photo_url
                    ELSE pr.profile_image_url
                END AS profile_image_url
           FROM (((public.chat_room_members m2
             JOIN public.public_profiles pr ON ((pr.id = m2.user_id)))
             JOIN public.users u2 ON ((u2.id = m2.user_id)))
             LEFT JOIN public.business_profiles bp ON (((bp.user_id = m2.user_id) AND ((bp.status)::text = 'approved'::text))))
          WHERE ((m2.room_id = r.id) AND (m2.user_id <> app.uid()) AND (((r.room_type)::text <> 'admin_inquiry'::text) OR ((u2.user_type)::text <> 'admin'::text)))
         LIMIT 1) AS other_profile_image_url,
    r.context
   FROM (public.chat_room_members m
     JOIN public.chat_rooms r ON ((r.id = m.room_id)))
  WHERE ((m.user_id = app.uid()) AND (m.left_at IS NULL));


--
-- Name: v_comment_feed; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_comment_feed AS
 SELECT c.id,
    c.post_id,
    c.user_id,
    c.content,
    c.created_at,
    (
        CASE
            WHEN ((c.authored_as)::text = 'business'::text) THEN COALESCE(bp.business_name, '업체'::text)
            ELSE (pr.nickname)::text
        END)::character varying(50) AS author_nickname,
    c.authored_as
   FROM ((public.comments c
     LEFT JOIN public.public_profiles pr ON ((pr.id = c.user_id)))
     LEFT JOIN public.business_profiles bp ON (((bp.user_id = c.user_id) AND ((bp.status)::text = 'approved'::text))))
  WHERE (c.is_deleted = false);


--
-- Name: v_facility_review_comment_feed; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_facility_review_comment_feed AS
 SELECT c.id,
    c.review_id,
    c.user_id,
    c.content,
    c.created_at,
    (
        CASE
            WHEN ((c.authored_as)::text = 'business'::text) THEN COALESCE(bp.business_name, '업체'::text)
            ELSE (pr.nickname)::text
        END)::character varying(50) AS author_nickname,
    c.authored_as
   FROM ((public.facility_review_comments c
     LEFT JOIN public.public_profiles pr ON ((pr.id = c.user_id)))
     LEFT JOIN public.business_profiles bp ON (((bp.user_id = c.user_id) AND ((bp.status)::text = 'approved'::text))))
  WHERE (c.is_deleted = false);


--
-- Name: v_pawing; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_pawing WITH (security_invoker='true') AS
 SELECT pr.id AS user_id,
    (
        CASE
            WHEN ((p.context)::text = 'business'::text) THEN COALESCE(pr.business_name, '업체'::text)
            ELSE (pr.nickname)::text
        END)::character varying(50) AS nickname,
    pr.user_type,
    p.created_at,
        CASE
            WHEN ((p.context)::text = 'business'::text) THEN pr.business_photo_url
            ELSE pr.profile_image_url
        END AS profile_image_url,
    ((p.context)::text = 'business'::text) AS is_business,
        CASE
            WHEN ((p.context)::text = 'business'::text) THEN pr.business_name
            ELSE NULL::text
        END AS business_name
   FROM (public.pawings p
     JOIN public.public_profiles pr ON ((pr.id = p.following_id)))
  WHERE (p.follower_id = app.uid());


--
-- Name: v_pawmate; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_pawmate WITH (security_invoker='true') AS
 SELECT pr.id AS user_id,
    pr.nickname,
    pr.user_type,
    p.created_at,
    (EXISTS ( SELECT 1
           FROM public.pawings me
          WHERE ((me.follower_id = app.uid()) AND (me.following_id = p.follower_id)))) AS i_follow_back,
    pr.profile_image_url
   FROM (public.pawings p
     JOIN public.public_profiles pr ON ((pr.id = p.follower_id)))
  WHERE ((p.following_id = app.uid()) AND ((p.context)::text = (COALESCE(( SELECT users.active_mode
           FROM public.users
          WHERE (users.id = app.uid())), 'personal'::character varying))::text));


--
-- Name: v_post_feed; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_post_feed AS
 SELECT p.id,
    p.category,
    p.title,
    p.content,
    p.user_id,
    (
        CASE
            WHEN ((p.authored_as)::text = 'business'::text) THEN COALESCE(bp.business_name, '업체'::text)
            ELSE (pr.nickname)::text
        END)::character varying(50) AS author_nickname,
    pr.user_type AS author_user_type,
    p.created_at,
    p.scheduled_at,
    p.display_address AS location,
    p.heart_count,
    p.comment_count,
    p.view_count,
    p.progress_status,
    (EXISTS ( SELECT 1
           FROM public.post_hearts h
          WHERE ((h.post_id = p.id) AND (h.user_id = app.uid())))) AS hearted,
    p.image_url,
    p.region_code,
    (
        CASE
            WHEN ((p.authored_as)::text = 'business'::text) THEN NULL::character varying
            ELSE pr.address
        END)::character varying(100) AS author_address,
    p.edited_at,
    p.authored_as
   FROM ((public.posts p
     LEFT JOIN public.public_profiles pr ON ((pr.id = p.user_id)))
     LEFT JOIN public.business_profiles bp ON (((bp.user_id = p.user_id) AND ((bp.status)::text = 'approved'::text))))
  WHERE (((p.visibility_status)::text = 'visible'::text) OR (((p.visibility_status)::text = 'hidden_by_user'::text) AND (p.user_id = app.uid())) OR app.is_admin());


--
-- Name: auth_logs auth_logs_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.auth_logs
    ADD CONSTRAINT auth_logs_pkey PRIMARY KEY (id);


--
-- Name: business_doc_purge_queue business_doc_purge_queue_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_doc_purge_queue
    ADD CONSTRAINT business_doc_purge_queue_pkey PRIMARY KEY (id);


--
-- Name: business_licenses business_licenses_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_licenses
    ADD CONSTRAINT business_licenses_pkey PRIMARY KEY (id);


--
-- Name: business_licenses business_licenses_user_id_license_type_key; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_licenses
    ADD CONSTRAINT business_licenses_user_id_license_type_key UNIQUE (user_id, license_type);


--
-- Name: business_purge_config business_purge_config_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_purge_config
    ADD CONSTRAINT business_purge_config_pkey PRIMARY KEY (id);


--
-- Name: funnel_events funnel_events_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.funnel_events
    ADD CONSTRAINT funnel_events_pkey PRIMARY KEY (id);


--
-- Name: location_usage_logs location_usage_logs_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.location_usage_logs
    ADD CONSTRAINT location_usage_logs_pkey PRIMARY KEY (id);


--
-- Name: push_config push_config_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.push_config
    ADD CONSTRAINT push_config_pkey PRIMARY KEY (id);


--
-- Name: rate_limits rate_limits_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.rate_limits
    ADD CONSTRAINT rate_limits_pkey PRIMARY KEY (bucket);


--
-- Name: refresh_tokens refresh_tokens_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.refresh_tokens
    ADD CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: refresh_tokens refresh_tokens_token_hash_key; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.refresh_tokens
    ADD CONSTRAINT refresh_tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: share_links share_links_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.share_links
    ADD CONSTRAINT share_links_pkey PRIMARY KEY (token);


--
-- Name: withdrawn_users withdrawn_users_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.withdrawn_users
    ADD CONSTRAINT withdrawn_users_pkey PRIMARY KEY (user_id);


--
-- Name: admin_logs admin_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_logs
    ADD CONSTRAINT admin_logs_pkey PRIMARY KEY (id);


--
-- Name: applications applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_pkey PRIMARY KEY (id);


--
-- Name: applications applications_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_uq UNIQUE (post_id, applicant_id);


--
-- Name: appointments appointments_application_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_application_id_key UNIQUE (application_id);


--
-- Name: appointments appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_pkey PRIMARY KEY (id);


--
-- Name: business_match_rules business_match_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_match_rules
    ADD CONSTRAINT business_match_rules_pkey PRIMARY KEY (rule_key);


--
-- Name: business_profiles business_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profiles
    ADD CONSTRAINT business_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: chat_message_deletions chat_message_deletions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_deletions
    ADD CONSTRAINT chat_message_deletions_pkey PRIMARY KEY (id);


--
-- Name: chat_message_deletions chat_message_deletions_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_deletions
    ADD CONSTRAINT chat_message_deletions_uq UNIQUE (message_id, user_id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_room_members chat_room_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_room_members
    ADD CONSTRAINT chat_room_members_pkey PRIMARY KEY (id);


--
-- Name: chat_room_members chat_room_members_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_room_members
    ADD CONSTRAINT chat_room_members_uq UNIQUE (room_id, user_id);


--
-- Name: chat_rooms chat_rooms_canonical_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_rooms
    ADD CONSTRAINT chat_rooms_canonical_key_key UNIQUE (canonical_key);


--
-- Name: chat_rooms chat_rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_rooms
    ADD CONSTRAINT chat_rooms_pkey PRIMARY KEY (id);


--
-- Name: comments comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_token_key UNIQUE (token);


--
-- Name: dong_centroids dong_centroids_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dong_centroids
    ADD CONSTRAINT dong_centroids_pkey PRIMARY KEY (region_code);


--
-- Name: facilities facilities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facilities
    ADD CONSTRAINT facilities_pkey PRIMARY KEY (id);


--
-- Name: facilities facilities_src_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facilities
    ADD CONSTRAINT facilities_src_uq UNIQUE (source, ext_id);


--
-- Name: facility_cache facility_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_cache
    ADD CONSTRAINT facility_cache_pkey PRIMARY KEY (id);


--
-- Name: facility_cache facility_cache_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_cache
    ADD CONSTRAINT facility_cache_uq UNIQUE (kakao_place_id, source_provider);


--
-- Name: facility_review_comments facility_review_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_review_comments
    ADD CONSTRAINT facility_review_comments_pkey PRIMARY KEY (id);


--
-- Name: facility_reviews facility_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_reviews
    ADD CONSTRAINT facility_reviews_pkey PRIMARY KEY (id);


--
-- Name: location_verifications location_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.location_verifications
    ADD CONSTRAINT location_verifications_pkey PRIMARY KEY (id);


--
-- Name: notification_preferences notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_pkey PRIMARY KEY (id);


--
-- Name: notification_preferences notification_preferences_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_user_id_key UNIQUE (user_id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: pawings pawings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pawings
    ADD CONSTRAINT pawings_pkey PRIMARY KEY (id);


--
-- Name: pawings pawings_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pawings
    ADD CONSTRAINT pawings_uq UNIQUE (follower_id, following_id, context);


--
-- Name: pet_guardian_invites pet_guardian_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardian_invites
    ADD CONSTRAINT pet_guardian_invites_pkey PRIMARY KEY (id);


--
-- Name: pet_guardians pet_guardians_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardians
    ADD CONSTRAINT pet_guardians_pkey PRIMARY KEY (id);


--
-- Name: pet_guardians pet_guardians_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardians
    ADD CONSTRAINT pet_guardians_uq UNIQUE (pet_id, user_id);


--
-- Name: pet_identity_frames pet_identity_frames_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_identity_frames
    ADD CONSTRAINT pet_identity_frames_pkey PRIMARY KEY (id);


--
-- Name: pet_identity_frames pet_identity_frames_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_identity_frames
    ADD CONSTRAINT pet_identity_frames_uq UNIQUE (pet_id, frame_index);


--
-- Name: pets pets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pets
    ADD CONSTRAINT pets_pkey PRIMARY KEY (id);


--
-- Name: phone_verifications phone_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_verifications
    ADD CONSTRAINT phone_verifications_pkey PRIMARY KEY (id);


--
-- Name: photo_verifications photo_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_verifications
    ADD CONSTRAINT photo_verifications_pkey PRIMARY KEY (id);


--
-- Name: post_hearts post_hearts_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hearts
    ADD CONSTRAINT post_hearts_uq UNIQUE (post_id, user_id);


--
-- Name: post_hearts post_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hearts
    ADD CONSTRAINT post_likes_pkey PRIMARY KEY (id);


--
-- Name: post_pets post_pets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_pets
    ADD CONSTRAINT post_pets_pkey PRIMARY KEY (id);


--
-- Name: post_pets post_pets_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_pets
    ADD CONSTRAINT post_pets_uq UNIQUE (post_id, pet_id);


--
-- Name: post_views post_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_pkey PRIMARY KEY (id);


--
-- Name: posts posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT posts_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: reports reports_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_uq UNIQUE (reporter_id, target_id, target_type);


--
-- Name: review_category_counts review_category_counts_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_category_counts
    ADD CONSTRAINT review_category_counts_pk PRIMARY KEY (user_id, category);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_uq UNIQUE (appointment_id, reviewer_id);


--
-- Name: user_blocks user_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_pkey PRIMARY KEY (id);


--
-- Name: user_blocks user_blocks_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_uq UNIQUE (blocker_id, blocked_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: funnel_events_token_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX funnel_events_token_idx ON app.funnel_events USING btree (token, event);


--
-- Name: idx_auth_logs_created; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX idx_auth_logs_created ON app.auth_logs USING btree (created_at);


--
-- Name: idx_location_usage_logs_used; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX idx_location_usage_logs_used ON app.location_usage_logs USING btree (used_at);


--
-- Name: idx_location_usage_logs_user; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX idx_location_usage_logs_user ON app.location_usage_logs USING btree (user_id, used_at DESC);


--
-- Name: rate_limits_expires_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX rate_limits_expires_idx ON app.rate_limits USING btree (expires_at);


--
-- Name: refresh_tokens_family_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX refresh_tokens_family_idx ON app.refresh_tokens USING btree (family_id);


--
-- Name: refresh_tokens_user_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX refresh_tokens_user_idx ON app.refresh_tokens USING btree (user_id);


--
-- Name: share_links_ref_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX share_links_ref_idx ON app.share_links USING btree (kind, ref_id);


--
-- Name: admin_logs_admin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX admin_logs_admin_idx ON public.admin_logs USING btree (admin_id, created_at DESC);


--
-- Name: admin_logs_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX admin_logs_target_idx ON public.admin_logs USING btree (target_type, target_id);


--
-- Name: applications_applicant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX applications_applicant_idx ON public.applications USING btree (applicant_id);


--
-- Name: applications_offered_pet_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX applications_offered_pet_idx ON public.applications USING btree (offered_pet_id) WHERE (offered_pet_id IS NOT NULL);


--
-- Name: applications_post_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX applications_post_status_idx ON public.applications USING btree (post_id, status);


--
-- Name: appointments_active_post_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX appointments_active_post_uq ON public.appointments USING btree (post_id) WHERE ((status)::text = 'scheduled'::text);


--
-- Name: appointments_applicant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_applicant_idx ON public.appointments USING btree (applicant_id);


--
-- Name: appointments_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_owner_idx ON public.appointments USING btree (post_owner_id);


--
-- Name: appointments_post_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX appointments_post_idx ON public.appointments USING btree (post_id);


--
-- Name: business_profiles_bizkey_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX business_profiles_bizkey_active_uq ON public.business_profiles USING btree (matched_biz_key) WHERE ((matched_biz_key IS NOT NULL) AND ((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying])::text[])));


--
-- Name: business_profiles_regno_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX business_profiles_regno_active_uq ON public.business_profiles USING btree (business_reg_no) WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying])::text[]));


--
-- Name: chat_messages_room_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_messages_room_order_idx ON public.chat_messages USING btree (room_id, created_at, id);


--
-- Name: chat_room_members_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_room_members_user_idx ON public.chat_room_members USING btree (user_id);


--
-- Name: chat_rooms_last_msg_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_rooms_last_msg_idx ON public.chat_rooms USING btree (last_message_at DESC);


--
-- Name: comments_post_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX comments_post_idx ON public.comments USING btree (post_id, created_at) WHERE (is_deleted = false);


--
-- Name: comments_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX comments_user_idx ON public.comments USING btree (user_id);


--
-- Name: device_tokens_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX device_tokens_active_idx ON public.device_tokens USING btree (user_id) WHERE (is_active = true);


--
-- Name: facilities_cat_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facilities_cat_idx ON public.facilities USING btree (category) WHERE is_open;


--
-- Name: facilities_geom_gix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facilities_geom_gix ON public.facilities USING gist (geom);


--
-- Name: facilities_name_addr_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facilities_name_addr_idx ON public.facilities USING btree (name, address);


--
-- Name: facilities_norm_name_trgm_gix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facilities_norm_name_trgm_gix ON public.facilities USING gin (app.norm_biz_text((name)::text) extensions.gin_trgm_ops);


--
-- Name: facility_cache_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facility_cache_category_idx ON public.facility_cache USING btree (category);


--
-- Name: facility_cache_coord_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facility_cache_coord_idx ON public.facility_cache USING btree (lat, lng);


--
-- Name: facility_cache_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facility_cache_expires_idx ON public.facility_cache USING btree (expires_at);


--
-- Name: facility_reviews_facility_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facility_reviews_facility_idx ON public.facility_reviews USING btree (facility_id, created_at DESC);


--
-- Name: frc_review_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX frc_review_idx ON public.facility_review_comments USING btree (review_id, created_at) WHERE (is_deleted = false);


--
-- Name: frc_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX frc_user_idx ON public.facility_review_comments USING btree (user_id);


--
-- Name: location_verifications_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX location_verifications_user_idx ON public.location_verifications USING btree (user_id, created_at DESC);


--
-- Name: notifications_group_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX notifications_group_uq ON public.notifications USING btree (user_id, notification_group_key) WHERE ((is_read = false) AND (notification_group_key IS NOT NULL));


--
-- Name: notifications_push_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_push_pending_idx ON public.notifications USING btree (created_at) WHERE ((push_status)::text = 'pending'::text);


--
-- Name: notifications_unread_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_unread_idx ON public.notifications USING btree (user_id, created_at DESC) WHERE (is_read = false);


--
-- Name: notifications_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_user_created_idx ON public.notifications USING btree (user_id, created_at DESC);


--
-- Name: pawings_following_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pawings_following_idx ON public.pawings USING btree (following_id);


--
-- Name: pawings_unnotified_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pawings_unnotified_idx ON public.pawings USING btree (created_at) WHERE (NOT notified);


--
-- Name: pet_guardians_one_owner_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pet_guardians_one_owner_uq ON public.pet_guardians USING btree (pet_id) WHERE ((role)::text = 'owner'::text);


--
-- Name: pet_guardians_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pet_guardians_user_idx ON public.pet_guardians USING btree (user_id);


--
-- Name: pet_identity_frames_pet_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pet_identity_frames_pet_idx ON public.pet_identity_frames USING btree (pet_id);


--
-- Name: pets_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pets_active_idx ON public.pets USING btree (primary_guardian_id) WHERE ((pet_status)::text = 'active'::text);


--
-- Name: pets_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pets_user_id_idx ON public.pets USING btree (primary_guardian_id);


--
-- Name: pgi_invitee_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pgi_invitee_idx ON public.pet_guardian_invites USING btree (invitee_user_id) WHERE ((status)::text = 'pending'::text);


--
-- Name: pgi_pending_phone_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pgi_pending_phone_uq ON public.pet_guardian_invites USING btree (pet_id, invitee_phone) WHERE (((status)::text = 'pending'::text) AND (invitee_phone IS NOT NULL));


--
-- Name: pgi_pending_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pgi_pending_user_uq ON public.pet_guardian_invites USING btree (pet_id, invitee_user_id) WHERE (((status)::text = 'pending'::text) AND (invitee_user_id IS NOT NULL));


--
-- Name: pgi_pet_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pgi_pet_idx ON public.pet_guardian_invites USING btree (pet_id, status);


--
-- Name: pgi_phone_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pgi_phone_idx ON public.pet_guardian_invites USING btree (invitee_phone) WHERE ((status)::text = 'pending'::text);


--
-- Name: phone_verifications_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_verifications_expires_idx ON public.phone_verifications USING btree (expires_at);


--
-- Name: phone_verifications_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_verifications_lookup_idx ON public.phone_verifications USING btree (phone, purpose, created_at DESC);


--
-- Name: photo_verifications_token_open_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX photo_verifications_token_open_idx ON public.photo_verifications USING btree (id) WHERE ((consumed_at IS NULL) AND ((result)::text = 'pass'::text));


--
-- Name: photo_verifications_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX photo_verifications_user_idx ON public.photo_verifications USING btree (user_id, created_at DESC);


--
-- Name: post_hearts_unnotified_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_hearts_unnotified_idx ON public.post_hearts USING btree (created_at) WHERE (NOT notified);


--
-- Name: post_hearts_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_hearts_user_idx ON public.post_hearts USING btree (user_id);


--
-- Name: post_pets_pet_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_pets_pet_idx ON public.post_pets USING btree (pet_id);


--
-- Name: post_views_ip_bucket_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_views_ip_bucket_uq ON public.post_views USING btree (post_id, ip_hash, view_bucket) WHERE (ip_hash IS NOT NULL);


--
-- Name: post_views_post_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_post_idx ON public.post_views USING btree (post_id);


--
-- Name: post_views_user_bucket_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX post_views_user_bucket_uq ON public.post_views USING btree (post_id, user_id, view_bucket) WHERE (user_id IS NOT NULL);


--
-- Name: post_views_viewed_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX post_views_viewed_idx ON public.post_views USING btree (viewed_at);


--
-- Name: posts_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_category_idx ON public.posts USING btree (category);


--
-- Name: posts_display_coord_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_display_coord_idx ON public.posts USING btree (display_lat, display_lng);


--
-- Name: posts_list_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_list_idx ON public.posts USING btree (visibility_status, progress_status, created_at DESC);


--
-- Name: posts_region_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_region_idx ON public.posts USING btree (region_code, progress_status, created_at DESC);


--
-- Name: posts_trgm_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_trgm_idx ON public.posts USING gin (((((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(content, ''::text))) extensions.gin_trgm_ops);


--
-- Name: posts_unnotified_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_unnotified_idx ON public.posts USING btree (created_at) WHERE (NOT pawing_notified);


--
-- Name: posts_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posts_user_id_idx ON public.posts USING btree (user_id);


--
-- Name: reports_one_open_per_target; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reports_one_open_per_target ON public.reports USING btree (reporter_id, target_type, target_id) WHERE ((status)::text = ANY ((ARRAY['submitted'::character varying, 'reviewing'::character varying])::text[]));


--
-- Name: INDEX reports_one_open_per_target; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON INDEX public.reports_one_open_per_target IS '신고자별 대상당 처리 중(open) 신고 1건 제한. 종료(resolved/dismissed) 후 재신고 허용';


--
-- Name: reports_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_status_idx ON public.reports USING btree (status);


--
-- Name: reports_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_target_idx ON public.reports USING btree (target_type, target_id);


--
-- Name: reviews_appointment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reviews_appointment_idx ON public.reviews USING btree (appointment_id);


--
-- Name: reviews_reviewee_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reviews_reviewee_idx ON public.reviews USING btree (reviewee_id);


--
-- Name: users_lower_nickname_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_lower_nickname_uq ON public.users USING btree (lower((nickname)::text));


--
-- Name: users_lower_username_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_lower_username_uq ON public.users USING btree (lower((username)::text));


--
-- Name: users_phone_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_phone_uq ON public.users USING btree (phone) WHERE (phone IS NOT NULL);


--
-- Name: users_region_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_region_code_idx ON public.users USING btree (region_code);


--
-- Name: users_user_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_user_type_idx ON public.users USING btree (user_type);


--
-- Name: business_licenses trg_business_licenses_updated; Type: TRIGGER; Schema: app; Owner: -
--

CREATE TRIGGER trg_business_licenses_updated BEFORE UPDATE ON app.business_licenses FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: facility_reviews facility_reviews_aggs; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER facility_reviews_aggs AFTER INSERT OR DELETE OR UPDATE ON public.facility_reviews FOR EACH ROW EXECUTE FUNCTION app.tg_facility_review_aggs();


--
-- Name: location_verifications log_location_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER log_location_usage AFTER INSERT ON public.location_verifications FOR EACH ROW EXECUTE FUNCTION app.tg_log_location_usage('활동지역 인증(GPS 검증)');


--
-- Name: photo_verifications log_location_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER log_location_usage AFTER INSERT ON public.photo_verifications FOR EACH ROW WHEN (((new.shot_lat IS NOT NULL) OR (new.shot_lng IS NOT NULL))) EXECUTE FUNCTION app.tg_log_location_usage('게시글 사진 촬영위치 검증');


--
-- Name: posts log_location_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER log_location_usage AFTER INSERT ON public.posts FOR EACH ROW WHEN (((new.actual_lat IS NOT NULL) OR (new.actual_lng IS NOT NULL))) EXECUTE FUNCTION app.tg_log_location_usage('게시글 작성 위치 기록');


--
-- Name: applications trg_applications_block_business; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_applications_block_business BEFORE INSERT ON public.applications FOR EACH ROW EXECUTE FUNCTION app.applications_block_business_mode();


--
-- Name: applications trg_applications_block_business_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_applications_block_business_update BEFORE UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_block_business_actor();


--
-- Name: applications trg_applications_block_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_applications_block_insert BEFORE INSERT ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_applications_block_insert();


--
-- Name: applications trg_applications_immutable_offer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_applications_immutable_offer BEFORE UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_applications_immutable_offer();


--
-- Name: applications trg_applications_on_accept; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_applications_on_accept AFTER UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_applications_on_accept();


--
-- Name: applications trg_applications_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_applications_updated BEFORE UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: appointments trg_appointments_after_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_appointments_after_update AFTER UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION app.tg_appointments_after_update();


--
-- Name: appointments trg_appointments_before_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_appointments_before_update BEFORE UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION app.tg_appointments_before_update();


--
-- Name: appointments trg_appointments_block_business; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_appointments_block_business BEFORE INSERT OR UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION app.tg_block_business_actor();


--
-- Name: appointments trg_appointments_pet_busy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_appointments_pet_busy BEFORE INSERT ON public.appointments FOR EACH ROW EXECUTE FUNCTION app.tg_appointments_pet_busy_check();


--
-- Name: appointments trg_appointments_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_appointments_updated BEFORE UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: comments trg_audit_comments; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_comments AFTER UPDATE ON public.comments FOR EACH ROW EXECUTE FUNCTION app.tg_audit_comments();


--
-- Name: posts trg_audit_posts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_posts AFTER UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_audit_posts();


--
-- Name: reports trg_audit_reports; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_reports AFTER UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION app.tg_audit_reports();


--
-- Name: chat_room_members trg_chat_members_read; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_members_read BEFORE UPDATE ON public.chat_room_members FOR EACH ROW EXECUTE FUNCTION app.tg_chat_members_read();


--
-- Name: chat_messages trg_chat_messages_after_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_messages_after_insert AFTER INSERT ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION app.tg_chat_messages_after_insert();


--
-- Name: chat_messages trg_chat_messages_after_softdelete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_messages_after_softdelete AFTER UPDATE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION app.tg_chat_messages_after_softdelete();


--
-- Name: chat_messages trg_chat_messages_block_left; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_messages_block_left BEFORE INSERT ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION app.chat_block_left_room();


--
-- Name: chat_messages trg_chat_messages_soft_delete_ts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_messages_soft_delete_ts BEFORE UPDATE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION app.tg_chat_messages_soft_delete_ts();


--
-- Name: chat_messages trg_chat_messages_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_messages_updated BEFORE UPDATE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: chat_room_members trg_chat_room_members_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_chat_room_members_updated BEFORE UPDATE ON public.chat_room_members FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: comments trg_comments_authored_as; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_comments_authored_as BEFORE INSERT ON public.comments FOR EACH ROW EXECUTE FUNCTION app.comments_set_authored_as();


--
-- Name: comments trg_comments_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_comments_count AFTER INSERT OR UPDATE ON public.comments FOR EACH ROW EXECUTE FUNCTION app.tg_comments_count();


--
-- Name: comments trg_comments_soft_delete_ts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_comments_soft_delete_ts BEFORE UPDATE ON public.comments FOR EACH ROW EXECUTE FUNCTION app.tg_comments_soft_delete_ts();


--
-- Name: device_tokens trg_device_tokens_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_device_tokens_updated BEFORE UPDATE ON public.device_tokens FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: facility_reviews trg_facility_review_recall; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_facility_review_recall AFTER UPDATE ON public.facility_reviews FOR EACH ROW EXECUTE FUNCTION app.tg_facility_review_recall();


--
-- Name: facility_review_comments trg_frc_authored_as; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_frc_authored_as BEFORE INSERT ON public.facility_review_comments FOR EACH ROW EXECUTE FUNCTION app.comments_set_authored_as();


--
-- Name: facility_review_comments trg_frc_soft_delete_ts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_frc_soft_delete_ts BEFORE UPDATE ON public.facility_review_comments FOR EACH ROW EXECUTE FUNCTION app.tg_frc_soft_delete_ts();


--
-- Name: notification_preferences trg_notification_preferences_upd; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notification_preferences_upd BEFORE UPDATE ON public.notification_preferences FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: notifications trg_notifications_push; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notifications_push AFTER INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION app.on_notification_push();


--
-- Name: notifications trg_notifications_read_ts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notifications_read_ts BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION app.tg_notifications_read_ts();


--
-- Name: notifications trg_notifications_unread_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notifications_unread_count AFTER INSERT OR DELETE OR UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION app.tg_notifications_unread_count();


--
-- Name: notifications trg_notifications_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notifications_updated BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: applications trg_notify_application; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_application AFTER INSERT ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_notify_application();


--
-- Name: applications trg_notify_application_accepted; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_application_accepted AFTER UPDATE ON public.applications FOR EACH ROW EXECUTE FUNCTION app.tg_notify_application_accepted();


--
-- Name: comments trg_notify_comment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_comment AFTER INSERT ON public.comments FOR EACH ROW EXECUTE FUNCTION app.tg_notify_comment();


--
-- Name: facility_reviews trg_notify_facility_review; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_facility_review AFTER INSERT ON public.facility_reviews FOR EACH ROW EXECUTE FUNCTION app.tg_notify_facility_review();


--
-- Name: pet_guardian_invites trg_notify_guardian_invite; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_guardian_invite AFTER INSERT ON public.pet_guardian_invites FOR EACH ROW EXECUTE FUNCTION app.tg_notify_guardian_invite();


--
-- Name: post_pets trg_notify_pet_in_post; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_pet_in_post AFTER INSERT ON public.post_pets FOR EACH ROW EXECUTE FUNCTION app.tg_notify_pet_in_post();


--
-- Name: reviews trg_notify_review; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_review AFTER INSERT ON public.reviews FOR EACH ROW EXECUTE FUNCTION app.tg_notify_review();


--
-- Name: facility_review_comments trg_notify_review_comment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_review_comment AFTER INSERT ON public.facility_review_comments FOR EACH ROW EXECUTE FUNCTION app.tg_notify_review_comment();


--
-- Name: pawings trg_pawings_recall; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pawings_recall AFTER DELETE ON public.pawings FOR EACH ROW EXECUTE FUNCTION app.tg_pawings_recall();


--
-- Name: pet_guardians trg_pet_guardians_owner_self_remove; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pet_guardians_owner_self_remove BEFORE DELETE ON public.pet_guardians FOR EACH ROW EXECUTE FUNCTION app.tg_pet_guardians_prevent_owner_self_remove();


--
-- Name: pets trg_pets_after_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pets_after_insert AFTER INSERT ON public.pets FOR EACH ROW EXECUTE FUNCTION app.tg_pets_after_insert();


--
-- Name: pets trg_pets_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pets_updated BEFORE UPDATE ON public.pets FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: pet_guardian_invites trg_pgi_resolve_invitee; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pgi_resolve_invitee BEFORE INSERT ON public.pet_guardian_invites FOR EACH ROW EXECUTE FUNCTION app.tg_pgi_resolve_invitee();


--
-- Name: pet_guardian_invites trg_pgi_respond; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pgi_respond BEFORE UPDATE ON public.pet_guardian_invites FOR EACH ROW EXECUTE FUNCTION app.tg_pet_guardian_invites_respond();


--
-- Name: post_hearts trg_post_hearts_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_hearts_count AFTER INSERT OR DELETE ON public.post_hearts FOR EACH ROW EXECUTE FUNCTION app.tg_post_hearts_count();


--
-- Name: post_hearts trg_post_hearts_recall; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_hearts_recall AFTER DELETE ON public.post_hearts FOR EACH ROW EXECUTE FUNCTION app.tg_post_hearts_recall();


--
-- Name: post_pets trg_post_pets_giveaway_limit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_pets_giveaway_limit BEFORE INSERT ON public.post_pets FOR EACH ROW EXECUTE FUNCTION app.tg_post_pets_giveaway_limit();


--
-- Name: post_views trg_post_views_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_views_count AFTER INSERT ON public.post_views FOR EACH ROW EXECUTE FUNCTION app.tg_post_views_count();


--
-- Name: posts trg_posts_authored_as; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_authored_as BEFORE INSERT ON public.posts FOR EACH ROW EXECUTE FUNCTION app.posts_set_authored_as();


--
-- Name: posts trg_posts_block_trader; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_block_trader BEFORE INSERT OR UPDATE OF category ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_posts_block_trader();


--
-- Name: posts trg_posts_check_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_check_write BEFORE INSERT ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_posts_check_write();


--
-- Name: posts trg_posts_deleted_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_deleted_at BEFORE INSERT OR UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_posts_deleted_at();


--
-- Name: posts trg_posts_set_region; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_set_region BEFORE INSERT ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_posts_set_region();


--
-- Name: posts trg_posts_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_updated BEFORE UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: posts trg_posts_validate_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_posts_validate_transition BEFORE UPDATE ON public.posts FOR EACH ROW EXECUTE FUNCTION app.tg_posts_validate_transition();


--
-- Name: reports trg_reports_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reports_updated BEFORE UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: review_category_counts trg_review_category_counts_upd; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_review_category_counts_upd BEFORE UPDATE ON public.review_category_counts FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: reviews trg_reviews_aggregate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reviews_aggregate AFTER INSERT ON public.reviews FOR EACH ROW EXECUTE FUNCTION app.tg_reviews_aggregate();


--
-- Name: reviews trg_reviews_block_business; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reviews_block_business BEFORE INSERT ON public.reviews FOR EACH ROW EXECUTE FUNCTION app.tg_block_business_actor();


--
-- Name: reviews trg_reviews_grant_pet_trust; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reviews_grant_pet_trust AFTER INSERT ON public.reviews FOR EACH ROW EXECUTE FUNCTION app.tg_reviews_grant_pet_trust();


--
-- Name: reviews trg_reviews_validate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reviews_validate BEFORE INSERT ON public.reviews FOR EACH ROW EXECUTE FUNCTION app.tg_reviews_validate();


--
-- Name: users trg_users_after_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_after_insert AFTER INSERT ON public.users FOR EACH ROW EXECUTE FUNCTION app.tg_users_after_insert();


--
-- Name: users trg_users_owner_succession; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_owner_succession AFTER UPDATE OF status ON public.users FOR EACH ROW EXECUTE FUNCTION app.tg_users_owner_succession();


--
-- Name: users trg_users_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_updated BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: auth_logs auth_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.auth_logs
    ADD CONSTRAINT auth_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: business_licenses business_licenses_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_licenses
    ADD CONSTRAINT business_licenses_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: business_licenses business_licenses_user_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_licenses
    ADD CONSTRAINT business_licenses_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: refresh_tokens refresh_tokens_replaced_by_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.refresh_tokens
    ADD CONSTRAINT refresh_tokens_replaced_by_fkey FOREIGN KEY (replaced_by) REFERENCES app.refresh_tokens(id) ON DELETE SET NULL;


--
-- Name: refresh_tokens refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.refresh_tokens
    ADD CONSTRAINT refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: share_links share_links_created_by_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.share_links
    ADD CONSTRAINT share_links_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: admin_logs admin_logs_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_logs
    ADD CONSTRAINT admin_logs_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.users(id);


--
-- Name: applications applications_applicant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_applicant_id_fkey FOREIGN KEY (applicant_id) REFERENCES public.users(id);


--
-- Name: applications applications_offered_pet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_offered_pet_id_fkey FOREIGN KEY (offered_pet_id) REFERENCES public.pets(id);


--
-- Name: applications applications_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id);


--
-- Name: appointments appointments_applicant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_applicant_id_fkey FOREIGN KEY (applicant_id) REFERENCES public.users(id);


--
-- Name: appointments appointments_application_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_application_id_fkey FOREIGN KEY (application_id) REFERENCES public.applications(id);


--
-- Name: appointments appointments_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id);


--
-- Name: appointments appointments_post_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_post_owner_id_fkey FOREIGN KEY (post_owner_id) REFERENCES public.users(id);


--
-- Name: business_profiles business_profiles_matched_facility_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profiles
    ADD CONSTRAINT business_profiles_matched_facility_id_fkey FOREIGN KEY (matched_facility_id) REFERENCES public.facilities(id) ON DELETE SET NULL;


--
-- Name: business_profiles business_profiles_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profiles
    ADD CONSTRAINT business_profiles_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: business_profiles business_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profiles
    ADD CONSTRAINT business_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: chat_message_deletions chat_message_deletions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_deletions
    ADD CONSTRAINT chat_message_deletions_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: chat_message_deletions chat_message_deletions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_message_deletions
    ADD CONSTRAINT chat_message_deletions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: chat_messages chat_messages_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.chat_rooms(id) ON DELETE CASCADE;


--
-- Name: chat_messages chat_messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id);


--
-- Name: chat_room_members chat_room_members_last_read_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_room_members
    ADD CONSTRAINT chat_room_members_last_read_message_id_fkey FOREIGN KEY (last_read_message_id) REFERENCES public.chat_messages(id) ON DELETE SET NULL;


--
-- Name: chat_room_members chat_room_members_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_room_members
    ADD CONSTRAINT chat_room_members_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.chat_rooms(id) ON DELETE CASCADE;


--
-- Name: chat_room_members chat_room_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_room_members
    ADD CONSTRAINT chat_room_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: chat_rooms chat_rooms_business_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_rooms
    ADD CONSTRAINT chat_rooms_business_user_id_fkey FOREIGN KEY (business_user_id) REFERENCES public.users(id);


--
-- Name: chat_rooms chat_rooms_last_message_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_rooms
    ADD CONSTRAINT chat_rooms_last_message_fk FOREIGN KEY (last_message_id) REFERENCES public.chat_messages(id) ON DELETE SET NULL;


--
-- Name: comments comments_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id);


--
-- Name: comments comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: device_tokens device_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: facility_review_comments facility_review_comments_review_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_review_comments
    ADD CONSTRAINT facility_review_comments_review_id_fkey FOREIGN KEY (review_id) REFERENCES public.facility_reviews(id) ON DELETE CASCADE;


--
-- Name: facility_review_comments facility_review_comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_review_comments
    ADD CONSTRAINT facility_review_comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: facility_reviews facility_reviews_facility_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_reviews
    ADD CONSTRAINT facility_reviews_facility_id_fkey FOREIGN KEY (facility_id) REFERENCES public.facilities(id) ON DELETE CASCADE;


--
-- Name: facility_reviews facility_reviews_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facility_reviews
    ADD CONSTRAINT facility_reviews_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: location_verifications location_verifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.location_verifications
    ADD CONSTRAINT location_verifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notification_preferences notification_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notifications notifications_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id);


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: pawings pawings_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pawings
    ADD CONSTRAINT pawings_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES public.users(id);


--
-- Name: pawings pawings_following_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pawings
    ADD CONSTRAINT pawings_following_id_fkey FOREIGN KEY (following_id) REFERENCES public.users(id);


--
-- Name: pet_guardian_invites pet_guardian_invites_invitee_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardian_invites
    ADD CONSTRAINT pet_guardian_invites_invitee_user_id_fkey FOREIGN KEY (invitee_user_id) REFERENCES public.users(id);


--
-- Name: pet_guardian_invites pet_guardian_invites_inviter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardian_invites
    ADD CONSTRAINT pet_guardian_invites_inviter_id_fkey FOREIGN KEY (inviter_id) REFERENCES public.users(id);


--
-- Name: pet_guardian_invites pet_guardian_invites_pet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardian_invites
    ADD CONSTRAINT pet_guardian_invites_pet_id_fkey FOREIGN KEY (pet_id) REFERENCES public.pets(id) ON DELETE CASCADE;


--
-- Name: pet_guardians pet_guardians_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardians
    ADD CONSTRAINT pet_guardians_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.users(id);


--
-- Name: pet_guardians pet_guardians_pet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardians
    ADD CONSTRAINT pet_guardians_pet_id_fkey FOREIGN KEY (pet_id) REFERENCES public.pets(id) ON DELETE CASCADE;


--
-- Name: pet_guardians pet_guardians_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_guardians
    ADD CONSTRAINT pet_guardians_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: pet_identity_frames pet_identity_frames_pet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pet_identity_frames
    ADD CONSTRAINT pet_identity_frames_pet_id_fkey FOREIGN KEY (pet_id) REFERENCES public.pets(id) ON DELETE CASCADE;


--
-- Name: pets pets_ai_ref_verification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pets
    ADD CONSTRAINT pets_ai_ref_verification_id_fkey FOREIGN KEY (ai_ref_verification_id) REFERENCES public.photo_verifications(id);


--
-- Name: pets pets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pets
    ADD CONSTRAINT pets_user_id_fkey FOREIGN KEY (primary_guardian_id) REFERENCES public.users(id);


--
-- Name: photo_verifications photo_verifications_pet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_verifications
    ADD CONSTRAINT photo_verifications_pet_id_fkey FOREIGN KEY (pet_id) REFERENCES public.pets(id);


--
-- Name: photo_verifications photo_verifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.photo_verifications
    ADD CONSTRAINT photo_verifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: post_hearts post_likes_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hearts
    ADD CONSTRAINT post_likes_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: post_hearts post_likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_hearts
    ADD CONSTRAINT post_likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: post_pets post_pets_pet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_pets
    ADD CONSTRAINT post_pets_pet_id_fkey FOREIGN KEY (pet_id) REFERENCES public.pets(id);


--
-- Name: post_pets post_pets_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_pets
    ADD CONSTRAINT post_pets_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: post_views post_views_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;


--
-- Name: post_views post_views_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_views
    ADD CONSTRAINT post_views_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: posts posts_photo_verification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT posts_photo_verification_id_fkey FOREIGN KEY (photo_verification_id) REFERENCES public.photo_verifications(id);


--
-- Name: posts posts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT posts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: reports reports_reporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES public.users(id);


--
-- Name: reports reports_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: review_category_counts review_category_counts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_category_counts
    ADD CONSTRAINT review_category_counts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: reviews reviews_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id);


--
-- Name: reviews reviews_reviewee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_reviewee_id_fkey FOREIGN KEY (reviewee_id) REFERENCES public.users(id);


--
-- Name: reviews reviews_reviewer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_reviewer_id_fkey FOREIGN KEY (reviewer_id) REFERENCES public.users(id);


--
-- Name: user_blocks user_blocks_blocked_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_blocked_id_fkey FOREIGN KEY (blocked_id) REFERENCES public.users(id);


--
-- Name: user_blocks user_blocks_blocker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_blocks
    ADD CONSTRAINT user_blocks_blocker_id_fkey FOREIGN KEY (blocker_id) REFERENCES public.users(id);


--
-- Name: auth_logs; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.auth_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: business_doc_purge_queue; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.business_doc_purge_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: business_purge_config; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.business_purge_config ENABLE ROW LEVEL SECURITY;

--
-- Name: location_usage_logs; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.location_usage_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: rate_limits; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.rate_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: refresh_tokens; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.refresh_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: withdrawn_users; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.withdrawn_users ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_logs admin_logs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_logs_select ON public.admin_logs FOR SELECT USING (app.is_admin());


--
-- Name: applications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;

--
-- Name: applications applications_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY applications_insert ON public.applications FOR INSERT WITH CHECK ((applicant_id = app.uid()));


--
-- Name: applications applications_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY applications_select ON public.applications FOR SELECT USING (((applicant_id = app.uid()) OR app.is_post_manager(post_id)));


--
-- Name: applications applications_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY applications_update ON public.applications FOR UPDATE USING (((applicant_id = app.uid()) OR app.is_post_manager(post_id)));


--
-- Name: appointments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.appointments ENABLE ROW LEVEL SECURITY;

--
-- Name: appointments appointments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointments_select ON public.appointments FOR SELECT USING (((post_owner_id = app.uid()) OR (applicant_id = app.uid()) OR app.is_admin()));


--
-- Name: appointments appointments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY appointments_update ON public.appointments FOR UPDATE USING (((post_owner_id = app.uid()) OR (applicant_id = app.uid()) OR app.is_admin())) WITH CHECK (((post_owner_id = app.uid()) OR (applicant_id = app.uid()) OR app.is_admin()));


--
-- Name: business_match_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_match_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: business_match_rules business_match_rules_admin_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_match_rules_admin_select ON public.business_match_rules FOR SELECT TO authenticated USING (app.is_admin());


--
-- Name: business_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: business_profiles business_profiles_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_profiles_select_own ON public.business_profiles FOR SELECT TO authenticated USING ((user_id = app.uid()));


--
-- Name: chat_message_deletions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_message_deletions ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_message_deletions chat_message_deletions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_message_deletions_insert ON public.chat_message_deletions FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: chat_message_deletions chat_message_deletions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_message_deletions_select ON public.chat_message_deletions FOR SELECT USING ((user_id = app.uid()));


--
-- Name: chat_messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_messages chat_messages_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_messages_insert ON public.chat_messages FOR INSERT WITH CHECK (((sender_id = app.uid()) AND app.is_room_member(room_id)));


--
-- Name: chat_messages chat_messages_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_messages_select ON public.chat_messages FOR SELECT USING ((app.is_room_member(room_id) OR app.is_admin()));


--
-- Name: chat_messages chat_messages_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_messages_update ON public.chat_messages FOR UPDATE USING (app.is_admin());


--
-- Name: chat_room_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_room_members ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_room_members chat_room_members_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_room_members_insert ON public.chat_room_members FOR INSERT WITH CHECK (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: chat_room_members chat_room_members_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_room_members_select ON public.chat_room_members FOR SELECT USING (((user_id = app.uid()) OR app.is_room_member(room_id) OR app.is_admin()));


--
-- Name: chat_room_members chat_room_members_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_room_members_update ON public.chat_room_members FOR UPDATE USING ((user_id = app.uid())) WITH CHECK ((user_id = app.uid()));


--
-- Name: chat_rooms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.chat_rooms ENABLE ROW LEVEL SECURITY;

--
-- Name: chat_rooms chat_rooms_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_rooms_insert ON public.chat_rooms FOR INSERT WITH CHECK ((app.uid() IS NOT NULL));


--
-- Name: chat_rooms chat_rooms_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_rooms_select ON public.chat_rooms FOR SELECT USING ((app.is_room_member(id) OR app.is_admin()));


--
-- Name: chat_rooms chat_rooms_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY chat_rooms_update ON public.chat_rooms FOR UPDATE USING (app.is_admin());


--
-- Name: comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

--
-- Name: comments comments_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY comments_insert ON public.comments FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: comments comments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY comments_select ON public.comments FOR SELECT USING (((is_deleted = false) OR app.is_admin()));


--
-- Name: comments comments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY comments_update ON public.comments FOR UPDATE USING (((user_id = app.uid()) OR app.is_admin())) WITH CHECK (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: device_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: device_tokens device_tokens_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY device_tokens_all ON public.device_tokens USING ((user_id = app.uid())) WITH CHECK ((user_id = app.uid()));


--
-- Name: dong_centroids; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.dong_centroids ENABLE ROW LEVEL SECURITY;

--
-- Name: facilities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.facilities ENABLE ROW LEVEL SECURITY;

--
-- Name: facilities facilities_select_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY facilities_select_all ON public.facilities FOR SELECT USING (true);


--
-- Name: facility_cache; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.facility_cache ENABLE ROW LEVEL SECURITY;

--
-- Name: facility_cache facility_cache_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY facility_cache_delete ON public.facility_cache FOR DELETE USING (app.is_admin());


--
-- Name: facility_cache facility_cache_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY facility_cache_insert ON public.facility_cache FOR INSERT WITH CHECK (app.is_admin());


--
-- Name: facility_cache facility_cache_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY facility_cache_select ON public.facility_cache FOR SELECT USING (true);


--
-- Name: facility_cache facility_cache_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY facility_cache_update ON public.facility_cache FOR UPDATE USING (app.is_admin()) WITH CHECK (app.is_admin());


--
-- Name: facility_review_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.facility_review_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: facility_reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.facility_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: facility_reviews fr_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fr_select ON public.facility_reviews FOR SELECT USING ((((visibility_status)::text = 'visible'::text) OR (user_id = app.uid())));


--
-- Name: facility_review_comments frc_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY frc_insert ON public.facility_review_comments FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: facility_review_comments frc_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY frc_select ON public.facility_review_comments FOR SELECT USING (((is_deleted = false) OR app.is_admin()));


--
-- Name: facility_review_comments frc_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY frc_update ON public.facility_review_comments FOR UPDATE USING (((user_id = app.uid()) OR app.is_admin())) WITH CHECK (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: location_verifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.location_verifications ENABLE ROW LEVEL SECURITY;

--
-- Name: location_verifications location_verifications_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY location_verifications_insert ON public.location_verifications FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: location_verifications location_verifications_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY location_verifications_select ON public.location_verifications FOR SELECT USING (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: notification_preferences; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_preferences notification_preferences_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notification_preferences_all ON public.notification_preferences USING ((user_id = app.uid())) WITH CHECK ((user_id = app.uid()));


--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_delete ON public.notifications FOR DELETE USING (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: notifications notifications_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_insert ON public.notifications FOR INSERT WITH CHECK (app.is_admin());


--
-- Name: notifications notifications_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_select ON public.notifications FOR SELECT USING (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: notifications notifications_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_update ON public.notifications FOR UPDATE USING (((user_id = app.uid()) OR app.is_admin())) WITH CHECK (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: pawings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pawings ENABLE ROW LEVEL SECURITY;

--
-- Name: pawings pawings_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pawings_delete ON public.pawings FOR DELETE USING ((follower_id = app.uid()));


--
-- Name: pawings pawings_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pawings_insert ON public.pawings FOR INSERT WITH CHECK ((follower_id = app.uid()));


--
-- Name: pawings pawings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pawings_select ON public.pawings FOR SELECT USING (true);


--
-- Name: pet_guardian_invites; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pet_guardian_invites ENABLE ROW LEVEL SECURITY;

--
-- Name: pet_guardians; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pet_guardians ENABLE ROW LEVEL SECURITY;

--
-- Name: pet_guardians pet_guardians_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pet_guardians_delete ON public.pet_guardians FOR DELETE USING ((app.is_pet_guardian(pet_id, 'owner'::text) OR app.is_admin()));


--
-- Name: pet_guardians pet_guardians_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pet_guardians_insert ON public.pet_guardians FOR INSERT WITH CHECK ((app.is_pet_guardian(pet_id, 'owner'::text) OR app.is_admin()));


--
-- Name: pet_guardians pet_guardians_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pet_guardians_select ON public.pet_guardians FOR SELECT USING ((app.is_pet_guardian(pet_id) OR app.is_admin()));


--
-- Name: pet_guardians pet_guardians_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pet_guardians_update ON public.pet_guardians FOR UPDATE USING ((app.is_pet_guardian(pet_id, 'owner'::text) OR app.is_admin())) WITH CHECK ((app.is_pet_guardian(pet_id, 'owner'::text) OR app.is_admin()));


--
-- Name: pet_identity_frames; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pet_identity_frames ENABLE ROW LEVEL SECURITY;

--
-- Name: pets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pets ENABLE ROW LEVEL SECURITY;

--
-- Name: pets pets_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pets_insert ON public.pets FOR INSERT WITH CHECK ((primary_guardian_id = app.uid()));


--
-- Name: pets pets_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pets_select ON public.pets FOR SELECT USING ((((pet_status)::text <> 'deleted'::text) OR app.is_pet_guardian(id) OR app.is_admin()));


--
-- Name: pets pets_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pets_update ON public.pets FOR UPDATE USING ((app.is_pet_guardian(id, 'owner'::text) OR app.is_admin())) WITH CHECK ((app.is_pet_guardian(id, 'owner'::text) OR app.is_admin()));


--
-- Name: pet_guardian_invites pgi_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pgi_insert ON public.pet_guardian_invites FOR INSERT WITH CHECK (((inviter_id = app.uid()) AND ((((kind)::text = 'invite'::text) AND app.is_pet_guardian(pet_id, 'owner'::text)) OR ((kind)::text = 'request'::text))));


--
-- Name: pet_guardian_invites pgi_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pgi_select ON public.pet_guardian_invites FOR SELECT USING (((inviter_id = app.uid()) OR (invitee_user_id = app.uid()) OR app.is_pet_guardian(pet_id, 'owner'::text) OR app.is_admin()));


--
-- Name: pet_guardian_invites pgi_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pgi_update ON public.pet_guardian_invites FOR UPDATE USING ((app.is_admin() OR (((kind)::text = 'invite'::text) AND (invitee_user_id = app.uid())) OR (((kind)::text = 'request'::text) AND app.is_pet_guardian(pet_id, 'owner'::text))));


--
-- Name: phone_verifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.phone_verifications ENABLE ROW LEVEL SECURITY;

--
-- Name: photo_verifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.photo_verifications ENABLE ROW LEVEL SECURITY;

--
-- Name: pet_identity_frames pif_select_guardian; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pif_select_guardian ON public.pet_identity_frames FOR SELECT USING (((EXISTS ( SELECT 1
   FROM public.pet_guardians g
  WHERE ((g.pet_id = pet_identity_frames.pet_id) AND (g.user_id = app.uid())))) OR app.is_admin()));


--
-- Name: post_hearts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_hearts ENABLE ROW LEVEL SECURITY;

--
-- Name: post_hearts post_hearts_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_hearts_delete ON public.post_hearts FOR DELETE USING ((user_id = app.uid()));


--
-- Name: post_hearts post_hearts_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_hearts_insert ON public.post_hearts FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: post_hearts post_hearts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_hearts_select ON public.post_hearts FOR SELECT USING (true);


--
-- Name: post_pets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_pets ENABLE ROW LEVEL SECURITY;

--
-- Name: post_pets post_pets_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_pets_delete ON public.post_pets FOR DELETE USING (((EXISTS ( SELECT 1
   FROM public.posts p
  WHERE ((p.id = post_pets.post_id) AND (p.user_id = app.uid())))) OR app.is_admin()));


--
-- Name: post_pets post_pets_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_pets_insert ON public.post_pets FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.posts p
  WHERE ((p.id = post_pets.post_id) AND (p.user_id = app.uid())))));


--
-- Name: post_pets post_pets_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_pets_select ON public.post_pets FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.posts p
  WHERE ((p.id = post_pets.post_id) AND (((p.visibility_status)::text = 'visible'::text) OR (p.user_id = app.uid()) OR app.is_admin())))));


--
-- Name: post_views; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_views ENABLE ROW LEVEL SECURITY;

--
-- Name: post_views post_views_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_views_insert ON public.post_views FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: post_views post_views_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY post_views_select ON public.post_views FOR SELECT USING (app.is_admin());


--
-- Name: posts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

--
-- Name: posts posts_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY posts_delete ON public.posts FOR DELETE USING (app.is_admin());


--
-- Name: posts posts_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY posts_insert ON public.posts FOR INSERT WITH CHECK ((user_id = app.uid()));


--
-- Name: posts posts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY posts_select ON public.posts FOR SELECT USING ((((visibility_status)::text = 'visible'::text) OR (((visibility_status)::text = 'hidden_by_user'::text) AND (user_id = app.uid())) OR app.is_admin()));


--
-- Name: posts posts_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY posts_update ON public.posts FOR UPDATE USING (((user_id = app.uid()) OR app.is_admin())) WITH CHECK (((user_id = app.uid()) OR app.is_admin()));


--
-- Name: reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

--
-- Name: reports reports_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reports_insert ON public.reports FOR INSERT WITH CHECK ((reporter_id = app.uid()));


--
-- Name: reports reports_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reports_select ON public.reports FOR SELECT USING (((reporter_id = app.uid()) OR app.is_admin()));


--
-- Name: reports reports_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reports_update ON public.reports FOR UPDATE USING (app.is_admin()) WITH CHECK (app.is_admin());


--
-- Name: review_category_counts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.review_category_counts ENABLE ROW LEVEL SECURITY;

--
-- Name: review_category_counts review_category_counts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY review_category_counts_select ON public.review_category_counts FOR SELECT USING (true);


--
-- Name: reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: reviews reviews_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reviews_insert ON public.reviews FOR INSERT WITH CHECK ((reviewer_id = app.uid()));


--
-- Name: reviews reviews_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reviews_select ON public.reviews FOR SELECT USING (true);


--
-- Name: user_blocks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

--
-- Name: user_blocks user_blocks_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_blocks_delete ON public.user_blocks FOR DELETE USING ((blocker_id = app.uid()));


--
-- Name: user_blocks user_blocks_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_blocks_insert ON public.user_blocks FOR INSERT WITH CHECK ((blocker_id = app.uid()));


--
-- Name: user_blocks user_blocks_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_blocks_select ON public.user_blocks FOR SELECT USING ((blocker_id = app.uid()));


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_select ON public.users FOR SELECT USING ((((status)::text <> 'suspended'::text) OR (id = app.uid()) OR app.is_admin()));


--
-- Name: users users_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_update ON public.users FOR UPDATE USING (((id = app.uid()) OR app.is_admin())) WITH CHECK (((id = app.uid()) OR app.is_admin()));


--
-- Name: SCHEMA app; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA app TO anon;
GRANT USAGE ON SCHEMA app TO authenticated;
GRANT USAGE ON SCHEMA app TO service_role;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION cleanup_auth(); Type: ACL; Schema: app; Owner: -
--

REVOKE ALL ON FUNCTION app.cleanup_auth() FROM PUBLIC;


--
-- Name: FUNCTION cleanup_retention(); Type: ACL; Schema: app; Owner: -
--

REVOKE ALL ON FUNCTION app.cleanup_retention() FROM PUBLIC;


--
-- Name: FUNCTION deactivate_device_token(p_token text, p_reason text); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.deactivate_device_token(p_token text, p_reason text) TO service_role;


--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.is_admin() TO anon;
GRANT ALL ON FUNCTION app.is_admin() TO authenticated;
GRANT ALL ON FUNCTION app.is_admin() TO service_role;


--
-- Name: FUNCTION is_pet_guardian(p_pet uuid, p_role text); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.is_pet_guardian(p_pet uuid, p_role text) TO anon;
GRANT ALL ON FUNCTION app.is_pet_guardian(p_pet uuid, p_role text) TO authenticated;
GRANT ALL ON FUNCTION app.is_pet_guardian(p_pet uuid, p_role text) TO service_role;


--
-- Name: FUNCTION is_room_member(p_room uuid); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.is_room_member(p_room uuid) TO anon;
GRANT ALL ON FUNCTION app.is_room_member(p_room uuid) TO authenticated;
GRANT ALL ON FUNCTION app.is_room_member(p_room uuid) TO service_role;


--
-- Name: FUNCTION mark_push_failed(p_notification_id uuid, p_error text, p_final boolean, p_max_attempts smallint); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.mark_push_failed(p_notification_id uuid, p_error text, p_final boolean, p_max_attempts smallint) TO service_role;


--
-- Name: FUNCTION mark_push_sent(p_notification_id uuid); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.mark_push_sent(p_notification_id uuid) TO service_role;


--
-- Name: FUNCTION mark_push_skipped(p_notification_id uuid, p_reason text); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.mark_push_skipped(p_notification_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION reconcile_unread_counts(p_user_id uuid); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.reconcile_unread_counts(p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION app.reconcile_unread_counts(p_user_id uuid) TO service_role;


--
-- Name: FUNCTION tg_log_location_usage(); Type: ACL; Schema: app; Owner: -
--

REVOKE ALL ON FUNCTION app.tg_log_location_usage() FROM PUBLIC;


--
-- Name: FUNCTION uid(); Type: ACL; Schema: app; Owner: -
--

GRANT ALL ON FUNCTION app.uid() TO anon;
GRANT ALL ON FUNCTION app.uid() TO authenticated;
GRANT ALL ON FUNCTION app.uid() TO service_role;


--
-- Name: FUNCTION _push_pref_allows(p_user uuid, p_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._push_pref_allows(p_user uuid, p_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public._push_pref_allows(p_user uuid, p_type text) TO service_role;


--
-- Name: FUNCTION add_facility_review(p_facility uuid, p_rating smallint, p_body text, p_paths text[], p_urls text[], p_has_incentive boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.add_facility_review(p_facility uuid, p_rating smallint, p_body text, p_paths text[], p_urls text[], p_has_incentive boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_facility_review(p_facility uuid, p_rating smallint, p_body text, p_paths text[], p_urls text[], p_has_incentive boolean) TO authenticated;
GRANT ALL ON FUNCTION public.add_facility_review(p_facility uuid, p_rating smallint, p_body text, p_paths text[], p_urls text[], p_has_incentive boolean) TO service_role;


--
-- Name: FUNCTION admin_broadcast_system_notice(p_title text, p_body text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_broadcast_system_notice(p_title text, p_body text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_broadcast_system_notice(p_title text, p_body text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_broadcast_system_notice(p_title text, p_body text) TO service_role;


--
-- Name: FUNCTION admin_create_facility_share_link(p_facility uuid, p_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_create_facility_share_link(p_facility uuid, p_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_create_facility_share_link(p_facility uuid, p_days integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_create_facility_share_link(p_facility uuid, p_days integer) TO service_role;


--
-- Name: FUNCTION admin_dashboard_stats(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_dashboard_stats() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_dashboard_stats() TO authenticated;
GRANT ALL ON FUNCTION public.admin_dashboard_stats() TO service_role;


--
-- Name: FUNCTION admin_get_report_target(p_report uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_get_report_target(p_report uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_get_report_target(p_report uuid) TO authenticated;
GRANT ALL ON FUNCTION public.admin_get_report_target(p_report uuid) TO service_role;


--
-- Name: FUNCTION admin_join_inquiry(p_room uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_join_inquiry(p_room uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_join_inquiry(p_room uuid) TO authenticated;
GRANT ALL ON FUNCTION public.admin_join_inquiry(p_room uuid) TO service_role;


--
-- Name: FUNCTION admin_list_business_applications(p_status text, p_track text, p_auto_only boolean, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_business_applications(p_status text, p_track text, p_auto_only boolean, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_business_applications(p_status text, p_track text, p_auto_only boolean, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_business_applications(p_status text, p_track text, p_auto_only boolean, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_list_business_licenses(p_status text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_business_licenses(p_status text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_business_licenses(p_status text, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_business_licenses(p_status text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_list_comments(p_post uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_comments(p_post uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_comments(p_post uuid) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_comments(p_post uuid) TO service_role;


--
-- Name: FUNCTION admin_list_inquiries(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_inquiries() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_inquiries() TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_inquiries() TO service_role;


--
-- Name: FUNCTION admin_list_logs(p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_logs(p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_logs(p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_logs(p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_list_posts(p_search text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_posts(p_search text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_posts(p_search text, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_posts(p_search text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_list_reports(p_status text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_reports(p_status text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_reports(p_status text, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_reports(p_status text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_list_users(p_search text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_list_users(p_search text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_list_users(p_search text, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_list_users(p_search text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_location_usage_logs(p_user uuid, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_location_usage_logs(p_user uuid, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_location_usage_logs(p_user uuid, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_location_usage_logs(p_user uuid, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_ops_metrics(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_ops_metrics() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_ops_metrics() TO authenticated;
GRANT ALL ON FUNCTION public.admin_ops_metrics() TO service_role;


--
-- Name: FUNCTION admin_photo_verification_failures(p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_photo_verification_failures(p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_photo_verification_failures(p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_photo_verification_failures(p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION admin_review_business_license(p_license uuid, p_status text, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_review_business_license(p_license uuid, p_status text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_review_business_license(p_license uuid, p_status text, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_review_business_license(p_license uuid, p_status text, p_reason text) TO service_role;


--
-- Name: FUNCTION admin_revoke_share_link(p_token character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_revoke_share_link(p_token character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_revoke_share_link(p_token character varying) TO authenticated;
GRANT ALL ON FUNCTION public.admin_revoke_share_link(p_token character varying) TO service_role;


--
-- Name: FUNCTION admin_room_messages(p_room uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_room_messages(p_room uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_room_messages(p_room uuid, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_room_messages(p_room uuid, p_limit integer) TO service_role;


--
-- Name: FUNCTION admin_set_business_status(p_user uuid, p_status text, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_business_status(p_user uuid, p_status text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_business_status(p_user uuid, p_status text, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_business_status(p_user uuid, p_status text, p_reason text) TO service_role;


--
-- Name: FUNCTION admin_set_chat_message_deleted(p_message uuid, p_deleted boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_chat_message_deleted(p_message uuid, p_deleted boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_chat_message_deleted(p_message uuid, p_deleted boolean) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_chat_message_deleted(p_message uuid, p_deleted boolean) TO service_role;


--
-- Name: FUNCTION admin_set_comment_deleted(p_comment uuid, p_deleted boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_comment_deleted(p_comment uuid, p_deleted boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_comment_deleted(p_comment uuid, p_deleted boolean) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_comment_deleted(p_comment uuid, p_deleted boolean) TO service_role;


--
-- Name: FUNCTION admin_set_match_rule(p_key text, p_weight integer, p_enabled boolean, p_params jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_match_rule(p_key text, p_weight integer, p_enabled boolean, p_params jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_match_rule(p_key text, p_weight integer, p_enabled boolean, p_params jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_match_rule(p_key text, p_weight integer, p_enabled boolean, p_params jsonb) TO service_role;


--
-- Name: FUNCTION admin_set_post_visibility(p_post uuid, p_visibility text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_post_visibility(p_post uuid, p_visibility text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_post_visibility(p_post uuid, p_visibility text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_post_visibility(p_post uuid, p_visibility text) TO service_role;


--
-- Name: FUNCTION admin_set_report_status(p_report uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_report_status(p_report uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_report_status(p_report uuid, p_status text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_report_status(p_report uuid, p_status text) TO service_role;


--
-- Name: FUNCTION admin_set_user_status(p_user uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_user_status(p_user uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_user_status(p_user uuid, p_status text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_user_status(p_user uuid, p_status text) TO service_role;


--
-- Name: FUNCTION apply_business_license(p_type text, p_license_no text, p_document_path text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.apply_business_license(p_type text, p_license_no text, p_document_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_business_license(p_type text, p_license_no text, p_document_path text) TO authenticated;
GRANT ALL ON FUNCTION public.apply_business_license(p_type text, p_license_no text, p_document_path text) TO service_role;


--
-- Name: FUNCTION apply_business_profile(p_user uuid, p_b_no text, p_category text, p_business_name text, p_storefront_name text, p_prev_name text, p_address_road text, p_address_jibun text, p_region_code text, p_phone text, p_rep_name text, p_email text, p_license_path text, p_extra_doc_path text, p_nts_status_code text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.apply_business_profile(p_user uuid, p_b_no text, p_category text, p_business_name text, p_storefront_name text, p_prev_name text, p_address_road text, p_address_jibun text, p_region_code text, p_phone text, p_rep_name text, p_email text, p_license_path text, p_extra_doc_path text, p_nts_status_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_business_profile(p_user uuid, p_b_no text, p_category text, p_business_name text, p_storefront_name text, p_prev_name text, p_address_road text, p_address_jibun text, p_region_code text, p_phone text, p_rep_name text, p_email text, p_license_path text, p_extra_doc_path text, p_nts_status_code text) TO service_role;


--
-- Name: FUNCTION bump_token_version(p_user uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.bump_token_version(p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.bump_token_version(p_user uuid) TO service_role;


--
-- Name: FUNCTION business_doc_purge_done(p_ids bigint[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.business_doc_purge_done(p_ids bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.business_doc_purge_done(p_ids bigint[]) TO service_role;


--
-- Name: FUNCTION business_doc_purge_take(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.business_doc_purge_take(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.business_doc_purge_take(p_limit integer) TO service_role;


--
-- Name: FUNCTION can_manage_post_applicants(p_post uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_manage_post_applicants(p_post uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_manage_post_applicants(p_post uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_manage_post_applicants(p_post uuid) TO service_role;


--
-- Name: FUNCTION change_password_and_rotate(p_user uuid, p_current_hash text, p_new_hash text, p_tv integer, p_new_token_hash text, p_user_agent text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.change_password_and_rotate(p_user uuid, p_current_hash text, p_new_hash text, p_tv integer, p_new_token_hash text, p_user_agent text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.change_password_and_rotate(p_user uuid, p_current_hash text, p_new_hash text, p_tv integer, p_new_token_hash text, p_user_agent text) TO service_role;


--
-- Name: FUNCTION check_nickname_available(p_nickname text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_nickname_available(p_nickname text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_nickname_available(p_nickname text) TO authenticated;
GRANT ALL ON FUNCTION public.check_nickname_available(p_nickname text) TO service_role;


--
-- Name: FUNCTION check_username_available(p_username text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_username_available(p_username text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_username_available(p_username text) TO anon;
GRANT ALL ON FUNCTION public.check_username_available(p_username text) TO authenticated;
GRANT ALL ON FUNCTION public.check_username_available(p_username text) TO service_role;


--
-- Name: FUNCTION create_post_verified(p_category character varying, p_title character varying, p_content text, p_scheduled_at timestamp with time zone, p_pet_ids uuid[], p_image_url text, p_image_mime character varying, p_image_size integer, p_photo_token uuid, p_actual_lat double precision, p_actual_lng double precision, p_region_code character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_post_verified(p_category character varying, p_title character varying, p_content text, p_scheduled_at timestamp with time zone, p_pet_ids uuid[], p_image_url text, p_image_mime character varying, p_image_size integer, p_photo_token uuid, p_actual_lat double precision, p_actual_lng double precision, p_region_code character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_post_verified(p_category character varying, p_title character varying, p_content text, p_scheduled_at timestamp with time zone, p_pet_ids uuid[], p_image_url text, p_image_mime character varying, p_image_size integer, p_photo_token uuid, p_actual_lat double precision, p_actual_lng double precision, p_region_code character varying) TO authenticated;
GRANT ALL ON FUNCTION public.create_post_verified(p_category character varying, p_title character varying, p_content text, p_scheduled_at timestamp with time zone, p_pet_ids uuid[], p_image_url text, p_image_mime character varying, p_image_size integer, p_photo_token uuid, p_actual_lat double precision, p_actual_lng double precision, p_region_code character varying) TO service_role;


--
-- Name: FUNCTION delete_facility_review(p_facility uuid, p_review uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_facility_review(p_facility uuid, p_review uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_facility_review(p_facility uuid, p_review uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_facility_review(p_facility uuid, p_review uuid) TO service_role;


--
-- Name: FUNCTION delete_my_chat_message(p_message uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_my_chat_message(p_message uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_my_chat_message(p_message uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_my_chat_message(p_message uuid) TO service_role;


--
-- Name: FUNCTION delete_my_post(p_post uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_my_post(p_post uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_my_post(p_post uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_my_post(p_post uuid) TO service_role;


--
-- Name: FUNCTION dong_centroid_seeds(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dong_centroid_seeds() FROM PUBLIC;
GRANT ALL ON FUNCTION public.dong_centroid_seeds() TO service_role;


--
-- Name: FUNCTION enroll_pet_identity(p_pet uuid, p_species character varying, p_paths text[], p_urls text[], p_breed character varying, p_colors text[], p_info_match jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enroll_pet_identity(p_pet uuid, p_species character varying, p_paths text[], p_urls text[], p_breed character varying, p_colors text[], p_info_match jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enroll_pet_identity(p_pet uuid, p_species character varying, p_paths text[], p_urls text[], p_breed character varying, p_colors text[], p_info_match jsonb) TO service_role;


--
-- Name: FUNCTION ensure_naver_facility(p_name text, p_address text, p_phone text, p_lng double precision, p_lat double precision); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ensure_naver_facility(p_name text, p_address text, p_phone text, p_lng double precision, p_lat double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ensure_naver_facility(p_name text, p_address text, p_phone text, p_lng double precision, p_lat double precision) TO authenticated;
GRANT ALL ON FUNCTION public.ensure_naver_facility(p_name text, p_address text, p_phone text, p_lng double precision, p_lat double precision) TO service_role;


--
-- Name: FUNCTION facilities_search(p_query text, p_lng double precision, p_lat double precision); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) TO authenticated;
GRANT ALL ON FUNCTION public.facilities_search(p_query text, p_lng double precision, p_lat double precision) TO service_role;


--
-- Name: FUNCTION facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) TO authenticated;
GRANT ALL ON FUNCTION public.facilities_within(p_lng double precision, p_lat double precision, p_radius_m integer, p_categories public.facility_category[]) TO service_role;


--
-- Name: FUNCTION facility_all_categories(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.facility_all_categories(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facility_all_categories(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.facility_all_categories(p_id uuid) TO service_role;


--
-- Name: FUNCTION facility_review_by_id(p_review uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.facility_review_by_id(p_review uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facility_review_by_id(p_review uuid) TO authenticated;
GRANT ALL ON FUNCTION public.facility_review_by_id(p_review uuid) TO service_role;


--
-- Name: FUNCTION facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) TO authenticated;
GRANT ALL ON FUNCTION public.facility_reviews_of(p_facility uuid, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION facility_sibling_ids(p_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.facility_sibling_ids(p_id uuid) TO anon;
GRANT ALL ON FUNCTION public.facility_sibling_ids(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.facility_sibling_ids(p_id uuid) TO service_role;


--
-- Name: FUNCTION feed_region_codes(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.feed_region_codes() FROM PUBLIC;
GRANT ALL ON FUNCTION public.feed_region_codes() TO authenticated;
GRANT ALL ON FUNCTION public.feed_region_codes() TO service_role;


--
-- Name: FUNCTION get_login_user(p_username text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_login_user(p_username text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_login_user(p_username text) TO service_role;


--
-- Name: FUNCTION get_password_hash(p_user uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_password_hash(p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_password_hash(p_user uuid) TO service_role;


--
-- Name: FUNCTION leave_chat_room(p_room uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.leave_chat_room(p_room uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.leave_chat_room(p_room uuid) TO authenticated;
GRANT ALL ON FUNCTION public.leave_chat_room(p_room uuid) TO service_role;


--
-- Name: FUNCTION login_issue_refresh(p_user uuid, p_token_hash text, p_user_agent text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.login_issue_refresh(p_user uuid, p_token_hash text, p_user_agent text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.login_issue_refresh(p_user uuid, p_token_hash text, p_user_agent text) TO service_role;


--
-- Name: FUNCTION my_business_licenses(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_business_licenses() FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_business_licenses() TO authenticated;
GRANT ALL ON FUNCTION public.my_business_licenses() TO service_role;


--
-- Name: FUNCTION naver_facility_id(p_name text, p_address text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.naver_facility_id(p_name text, p_address text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.naver_facility_id(p_name text, p_address text) TO authenticated;
GRANT ALL ON FUNCTION public.naver_facility_id(p_name text, p_address text) TO service_role;


--
-- Name: FUNCTION pet_guardians_of(p_pet uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pet_guardians_of(p_pet uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pet_guardians_of(p_pet uuid) TO authenticated;
GRANT ALL ON FUNCTION public.pet_guardians_of(p_pet uuid) TO service_role;


--
-- Name: FUNCTION posts_by_region(p_min_lng double precision, p_min_lat double precision, p_max_lng double precision, p_max_lat double precision); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.posts_by_region(p_min_lng double precision, p_min_lat double precision, p_max_lng double precision, p_max_lat double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION public.posts_by_region(p_min_lng double precision, p_min_lat double precision, p_max_lng double precision, p_max_lat double precision) TO authenticated;
GRANT ALL ON FUNCTION public.posts_by_region(p_min_lng double precision, p_min_lat double precision, p_max_lng double precision, p_max_lat double precision) TO service_role;


--
-- Name: FUNCTION public_user_pets(p_user uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.public_user_pets(p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_user_pets(p_user uuid) TO authenticated;
GRANT ALL ON FUNCTION public.public_user_pets(p_user uuid) TO service_role;


--
-- Name: FUNCTION push_dispatch_batch(p_only_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.push_dispatch_batch(p_only_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.push_dispatch_batch(p_only_id uuid, p_limit integer) TO service_role;


--
-- Name: FUNCTION push_report(p_results jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.push_report(p_results jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.push_report(p_results jsonb) TO service_role;


--
-- Name: FUNCTION rate_limit_hit(p_key text, p_max integer, p_window_seconds integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer) TO service_role;


--
-- Name: FUNCTION record_auth_log(p_user uuid, p_ip_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_auth_log(p_user uuid, p_ip_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_auth_log(p_user uuid, p_ip_hash text) TO service_role;


--
-- Name: FUNCTION record_location_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_result text, p_region_code character varying, p_address character varying, p_fail_reason character varying, p_fail_limit integer, p_block_minutes integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_location_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_result text, p_region_code character varying, p_address character varying, p_fail_reason character varying, p_fail_limit integer, p_block_minutes integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_location_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_result text, p_region_code character varying, p_address character varying, p_fail_reason character varying, p_fail_limit integer, p_block_minutes integer) TO service_role;


--
-- Name: FUNCTION record_photo_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_region_code character varying, p_region_matched boolean, p_species character varying, p_dog_real numeric, p_cat_real numeric, p_dog_fake numeric, p_cat_fake numeric, p_ai_pass boolean, p_ai_reason character varying, p_result text, p_fail_reason character varying, p_image_url text, p_image_path text, p_ttl_min integer, p_pet_id uuid, p_purpose text, p_match_score numeric, p_matched boolean, p_match_reason character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_photo_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_region_code character varying, p_region_matched boolean, p_species character varying, p_dog_real numeric, p_cat_real numeric, p_dog_fake numeric, p_cat_fake numeric, p_ai_pass boolean, p_ai_reason character varying, p_result text, p_fail_reason character varying, p_image_url text, p_image_path text, p_ttl_min integer, p_pet_id uuid, p_purpose text, p_match_score numeric, p_matched boolean, p_match_reason character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_photo_verification(p_user uuid, p_lat numeric, p_lng numeric, p_accuracy integer, p_region_code character varying, p_region_matched boolean, p_species character varying, p_dog_real numeric, p_cat_real numeric, p_dog_fake numeric, p_cat_fake numeric, p_ai_pass boolean, p_ai_reason character varying, p_result text, p_fail_reason character varying, p_image_url text, p_image_path text, p_ttl_min integer, p_pet_id uuid, p_purpose text, p_match_score numeric, p_matched boolean, p_match_reason character varying) TO service_role;


--
-- Name: FUNCTION register_device_token(p_token text, p_platform text, p_device_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_device_token(p_token text, p_platform text, p_device_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_device_token(p_token text, p_platform text, p_device_name text) TO authenticated;
GRANT ALL ON FUNCTION public.register_device_token(p_token text, p_platform text, p_device_name text) TO service_role;


--
-- Name: FUNCTION reset_password_user(p_phone text, p_new_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reset_password_user(p_phone text, p_new_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reset_password_user(p_phone text, p_new_hash text) TO service_role;


--
-- Name: FUNCTION review_owner_switch_hint(p_review uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.review_owner_switch_hint(p_review uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.review_owner_switch_hint(p_review uuid) TO authenticated;
GRANT ALL ON FUNCTION public.review_owner_switch_hint(p_review uuid) TO service_role;


--
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.rls_auto_enable() TO service_role;


--
-- Name: FUNCTION rt_issue(p_user uuid, p_token_hash text, p_user_agent text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rt_issue(p_user uuid, p_token_hash text, p_user_agent text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rt_issue(p_user uuid, p_token_hash text, p_user_agent text) TO service_role;


--
-- Name: FUNCTION rt_revoke_family(p_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rt_revoke_family(p_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rt_revoke_family(p_hash text) TO service_role;


--
-- Name: FUNCTION rt_revoke_user(p_user uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rt_revoke_user(p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rt_revoke_user(p_user uuid) TO service_role;


--
-- Name: FUNCTION rt_rotate(p_old_hash text, p_new_hash text, p_user_agent text, p_grace_seconds integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rt_rotate(p_old_hash text, p_new_hash text, p_user_agent text, p_grace_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rt_rotate(p_old_hash text, p_new_hash text, p_user_agent text, p_grace_seconds integer) TO service_role;


--
-- Name: FUNCTION session_alive(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.session_alive() TO anon;
GRANT ALL ON FUNCTION public.session_alive() TO authenticated;
GRANT ALL ON FUNCTION public.session_alive() TO service_role;


--
-- Name: FUNCTION set_activity_radius(p_m integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_activity_radius(p_m integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_activity_radius(p_m integer) TO authenticated;
GRANT ALL ON FUNCTION public.set_activity_radius(p_m integer) TO service_role;


--
-- Name: FUNCTION set_my_business_photo(p_url text, p_align_y real); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_my_business_photo(p_url text, p_align_y real) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_my_business_photo(p_url text, p_align_y real) TO authenticated;
GRANT ALL ON FUNCTION public.set_my_business_photo(p_url text, p_align_y real) TO service_role;


--
-- Name: FUNCTION set_pet_ai_reference(p_pet uuid, p_verification uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_pet_ai_reference(p_pet uuid, p_verification uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_pet_ai_reference(p_pet uuid, p_verification uuid) TO service_role;


--
-- Name: FUNCTION share_view_click(p_token character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.share_view_click(p_token character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.share_view_click(p_token character varying) TO service_role;


--
-- Name: FUNCTION share_view_load(p_token character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.share_view_load(p_token character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.share_view_load(p_token character varying) TO service_role;


--
-- Name: FUNCTION signup_user(p_username text, p_password_hash text, p_nickname text, p_user_type text, p_phone text, p_marketing boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.signup_user(p_username text, p_password_hash text, p_nickname text, p_user_type text, p_phone text, p_marketing boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.signup_user(p_username text, p_password_hash text, p_nickname text, p_user_type text, p_phone text, p_marketing boolean) TO service_role;


--
-- Name: FUNCTION start_direct_chat(p_other uuid, p_context text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.start_direct_chat(p_other uuid, p_context text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_direct_chat(p_other uuid, p_context text) TO authenticated;
GRANT ALL ON FUNCTION public.start_direct_chat(p_other uuid, p_context text) TO service_role;


--
-- Name: FUNCTION switch_account_mode(p_mode text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.switch_account_mode(p_mode text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.switch_account_mode(p_mode text) TO authenticated;
GRANT ALL ON FUNCTION public.switch_account_mode(p_mode text) TO service_role;


--
-- Name: FUNCTION update_my_business_info(p_storefront_name text, p_phone text, p_email text, p_hours text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_my_business_info(p_storefront_name text, p_phone text, p_email text, p_hours text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_my_business_info(p_storefront_name text, p_phone text, p_email text, p_hours text) TO authenticated;
GRANT ALL ON FUNCTION public.update_my_business_info(p_storefront_name text, p_phone text, p_email text, p_hours text) TO service_role;


--
-- Name: FUNCTION update_my_post(p_post uuid, p_title text, p_content text, p_scheduled_at timestamp with time zone, p_image_url text, p_image_mime character varying, p_image_size integer, p_edit_image boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_my_post(p_post uuid, p_title text, p_content text, p_scheduled_at timestamp with time zone, p_image_url text, p_image_mime character varying, p_image_size integer, p_edit_image boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_my_post(p_post uuid, p_title text, p_content text, p_scheduled_at timestamp with time zone, p_image_url text, p_image_mime character varying, p_image_size integer, p_edit_image boolean) TO authenticated;
GRANT ALL ON FUNCTION public.update_my_post(p_post uuid, p_title text, p_content text, p_scheduled_at timestamp with time zone, p_image_url text, p_image_mime character varying, p_image_size integer, p_edit_image boolean) TO service_role;


--
-- Name: FUNCTION update_password_hash(p_user uuid, p_old_hash text, p_new_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_password_hash(p_user uuid, p_old_hash text, p_new_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_password_hash(p_user uuid, p_old_hash text, p_new_hash text) TO service_role;


--
-- Name: FUNCTION withdraw_account(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.withdraw_account() FROM PUBLIC;
GRANT ALL ON FUNCTION public.withdraw_account() TO authenticated;
GRANT ALL ON FUNCTION public.withdraw_account() TO service_role;


--
-- Name: TABLE admin_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.admin_logs TO anon;
GRANT ALL ON TABLE public.admin_logs TO authenticated;
GRANT ALL ON TABLE public.admin_logs TO service_role;


--
-- Name: TABLE applications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.applications TO anon;
GRANT ALL ON TABLE public.applications TO authenticated;
GRANT ALL ON TABLE public.applications TO service_role;


--
-- Name: TABLE appointments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.appointments TO anon;
GRANT ALL ON TABLE public.appointments TO authenticated;
GRANT ALL ON TABLE public.appointments TO service_role;


--
-- Name: TABLE business_match_rules; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.business_match_rules TO anon;
GRANT ALL ON TABLE public.business_match_rules TO authenticated;
GRANT ALL ON TABLE public.business_match_rules TO service_role;


--
-- Name: TABLE business_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.business_profiles TO anon;
GRANT ALL ON TABLE public.business_profiles TO authenticated;
GRANT ALL ON TABLE public.business_profiles TO service_role;


--
-- Name: TABLE chat_message_deletions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.chat_message_deletions TO anon;
GRANT ALL ON TABLE public.chat_message_deletions TO authenticated;
GRANT ALL ON TABLE public.chat_message_deletions TO service_role;


--
-- Name: TABLE chat_messages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.chat_messages TO anon;
GRANT ALL ON TABLE public.chat_messages TO authenticated;
GRANT ALL ON TABLE public.chat_messages TO service_role;


--
-- Name: TABLE chat_room_members; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.chat_room_members TO anon;
GRANT ALL ON TABLE public.chat_room_members TO authenticated;
GRANT ALL ON TABLE public.chat_room_members TO service_role;


--
-- Name: TABLE chat_rooms; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.chat_rooms TO anon;
GRANT ALL ON TABLE public.chat_rooms TO authenticated;
GRANT ALL ON TABLE public.chat_rooms TO service_role;


--
-- Name: TABLE comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.comments TO anon;
GRANT ALL ON TABLE public.comments TO authenticated;
GRANT ALL ON TABLE public.comments TO service_role;


--
-- Name: COLUMN comments.authored_as; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(authored_as) ON TABLE public.comments TO authenticated;
GRANT SELECT(authored_as) ON TABLE public.comments TO anon;


--
-- Name: TABLE device_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.device_tokens TO anon;
GRANT ALL ON TABLE public.device_tokens TO authenticated;
GRANT ALL ON TABLE public.device_tokens TO service_role;


--
-- Name: TABLE dong_centroids; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.dong_centroids TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.dong_centroids TO authenticated;
GRANT ALL ON TABLE public.dong_centroids TO service_role;


--
-- Name: TABLE facilities; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.facilities TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.facilities TO authenticated;
GRANT ALL ON TABLE public.facilities TO service_role;


--
-- Name: TABLE facility_cache; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.facility_cache TO anon;
GRANT ALL ON TABLE public.facility_cache TO authenticated;
GRANT ALL ON TABLE public.facility_cache TO service_role;


--
-- Name: TABLE facility_review_comments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.facility_review_comments TO anon;
GRANT ALL ON TABLE public.facility_review_comments TO authenticated;
GRANT ALL ON TABLE public.facility_review_comments TO service_role;


--
-- Name: TABLE facility_reviews; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.facility_reviews TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.facility_reviews TO authenticated;
GRANT ALL ON TABLE public.facility_reviews TO service_role;


--
-- Name: TABLE location_verifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.location_verifications TO anon;
GRANT ALL ON TABLE public.location_verifications TO authenticated;
GRANT ALL ON TABLE public.location_verifications TO service_role;


--
-- Name: TABLE notification_preferences; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.notification_preferences TO anon;
GRANT ALL ON TABLE public.notification_preferences TO authenticated;
GRANT ALL ON TABLE public.notification_preferences TO service_role;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.notifications TO anon;
GRANT ALL ON TABLE public.notifications TO authenticated;
GRANT ALL ON TABLE public.notifications TO service_role;


--
-- Name: TABLE pawings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.pawings TO anon;
GRANT ALL ON TABLE public.pawings TO authenticated;
GRANT ALL ON TABLE public.pawings TO service_role;


--
-- Name: TABLE pet_guardian_invites; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.pet_guardian_invites TO anon;
GRANT ALL ON TABLE public.pet_guardian_invites TO authenticated;
GRANT ALL ON TABLE public.pet_guardian_invites TO service_role;


--
-- Name: TABLE pet_guardians; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.pet_guardians TO anon;
GRANT ALL ON TABLE public.pet_guardians TO authenticated;
GRANT ALL ON TABLE public.pet_guardians TO service_role;


--
-- Name: TABLE pet_identity_frames; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.pet_identity_frames TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.pet_identity_frames TO authenticated;
GRANT ALL ON TABLE public.pet_identity_frames TO service_role;


--
-- Name: COLUMN pet_identity_frames.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.pet_identity_frames TO authenticated;


--
-- Name: COLUMN pet_identity_frames.pet_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(pet_id) ON TABLE public.pet_identity_frames TO authenticated;


--
-- Name: COLUMN pet_identity_frames.frame_index; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(frame_index) ON TABLE public.pet_identity_frames TO authenticated;


--
-- Name: COLUMN pet_identity_frames.image_url; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_url) ON TABLE public.pet_identity_frames TO authenticated;


--
-- Name: COLUMN pet_identity_frames.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.pet_identity_frames TO authenticated;


--
-- Name: TABLE pets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.pets TO anon;
GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.pets TO authenticated;
GRANT ALL ON TABLE public.pets TO service_role;


--
-- Name: COLUMN pets.primary_guardian_id; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(primary_guardian_id) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.name; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(name),UPDATE(name) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.species; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(species),UPDATE(species) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.gender; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(gender),UPDATE(gender) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.birth_date; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(birth_date),UPDATE(birth_date) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.is_neutered; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(is_neutered),UPDATE(is_neutered) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.image_url; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(image_url),UPDATE(image_url) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.image_thumbnail_url; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(image_thumbnail_url),UPDATE(image_thumbnail_url) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.image_mime_type; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(image_mime_type),UPDATE(image_mime_type) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.image_file_size; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(image_file_size),UPDATE(image_file_size) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.image_width; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(image_width),UPDATE(image_width) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.image_height; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(image_height),UPDATE(image_height) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.bio; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(bio),UPDATE(bio) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.pet_status; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(pet_status) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.species_kind; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(species_kind),UPDATE(species_kind) ON TABLE public.pets TO authenticated;


--
-- Name: COLUMN pets.trust_score; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(trust_score) ON TABLE public.pets TO anon;
GRANT SELECT(trust_score) ON TABLE public.pets TO authenticated;


--
-- Name: TABLE phone_verifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.phone_verifications TO anon;
GRANT ALL ON TABLE public.phone_verifications TO authenticated;
GRANT ALL ON TABLE public.phone_verifications TO service_role;


--
-- Name: TABLE photo_verifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.photo_verifications TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.photo_verifications TO authenticated;
GRANT ALL ON TABLE public.photo_verifications TO service_role;


--
-- Name: TABLE post_hearts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.post_hearts TO anon;
GRANT ALL ON TABLE public.post_hearts TO authenticated;
GRANT ALL ON TABLE public.post_hearts TO service_role;


--
-- Name: TABLE post_pets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.post_pets TO anon;
GRANT ALL ON TABLE public.post_pets TO authenticated;
GRANT ALL ON TABLE public.post_pets TO service_role;


--
-- Name: TABLE post_views; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.post_views TO anon;
GRANT ALL ON TABLE public.post_views TO authenticated;
GRANT ALL ON TABLE public.post_views TO service_role;


--
-- Name: TABLE posts; Type: ACL; Schema: public; Owner: -
--

GRANT MAINTAIN ON TABLE public.posts TO anon;
GRANT REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.posts TO authenticated;
GRANT ALL ON TABLE public.posts TO service_role;


--
-- Name: COLUMN posts.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.posts TO anon;
GRANT SELECT(id),UPDATE(id) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.user_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(user_id) ON TABLE public.posts TO anon;
GRANT SELECT(user_id),INSERT(user_id),UPDATE(user_id) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.category; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(category) ON TABLE public.posts TO anon;
GRANT SELECT(category),INSERT(category),UPDATE(category) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.title; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(title) ON TABLE public.posts TO anon;
GRANT SELECT(title),INSERT(title),UPDATE(title) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.content; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(content) ON TABLE public.posts TO anon;
GRANT SELECT(content),INSERT(content),UPDATE(content) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.image_url; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_url) ON TABLE public.posts TO anon;
GRANT SELECT(image_url),INSERT(image_url),UPDATE(image_url) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.image_thumbnail_url; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_thumbnail_url) ON TABLE public.posts TO anon;
GRANT SELECT(image_thumbnail_url),INSERT(image_thumbnail_url),UPDATE(image_thumbnail_url) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.image_mime_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_mime_type) ON TABLE public.posts TO anon;
GRANT SELECT(image_mime_type),INSERT(image_mime_type),UPDATE(image_mime_type) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.image_file_size; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_file_size) ON TABLE public.posts TO anon;
GRANT SELECT(image_file_size),INSERT(image_file_size),UPDATE(image_file_size) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.image_width; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_width) ON TABLE public.posts TO anon;
GRANT SELECT(image_width),INSERT(image_width),UPDATE(image_width) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.image_height; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(image_height) ON TABLE public.posts TO anon;
GRANT SELECT(image_height),INSERT(image_height),UPDATE(image_height) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.scheduled_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(scheduled_at) ON TABLE public.posts TO anon;
GRANT SELECT(scheduled_at),INSERT(scheduled_at),UPDATE(scheduled_at) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.visibility_status; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(visibility_status) ON TABLE public.posts TO anon;
GRANT SELECT(visibility_status),UPDATE(visibility_status) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.progress_status; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(progress_status) ON TABLE public.posts TO anon;
GRANT SELECT(progress_status),UPDATE(progress_status) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.deleted_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(deleted_at) ON TABLE public.posts TO anon;
GRANT SELECT(deleted_at),UPDATE(deleted_at) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.view_count; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(view_count) ON TABLE public.posts TO anon;
GRANT SELECT(view_count) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.heart_count; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(heart_count) ON TABLE public.posts TO anon;
GRANT SELECT(heart_count) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.comment_count; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(comment_count) ON TABLE public.posts TO anon;
GRANT SELECT(comment_count) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.actual_lat; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(actual_lat) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.actual_lng; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(actual_lng) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.display_lat; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(display_lat) ON TABLE public.posts TO anon;
GRANT SELECT(display_lat),UPDATE(display_lat) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.display_lng; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(display_lng) ON TABLE public.posts TO anon;
GRANT SELECT(display_lng),UPDATE(display_lng) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.display_address; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(display_address) ON TABLE public.posts TO anon;
GRANT SELECT(display_address),UPDATE(display_address) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.region_code; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(region_code) ON TABLE public.posts TO anon;
GRANT SELECT(region_code),UPDATE(region_code) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.location_radius_m; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(location_radius_m) ON TABLE public.posts TO anon;
GRANT SELECT(location_radius_m),UPDATE(location_radius_m) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.is_location_hidden; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(is_location_hidden) ON TABLE public.posts TO anon;
GRANT SELECT(is_location_hidden),UPDATE(is_location_hidden) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.posts TO anon;
GRANT SELECT(created_at),UPDATE(created_at) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.updated_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(updated_at) ON TABLE public.posts TO anon;
GRANT SELECT(updated_at),UPDATE(updated_at) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.edited_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(edited_at) ON TABLE public.posts TO anon;
GRANT SELECT(edited_at) ON TABLE public.posts TO authenticated;


--
-- Name: COLUMN posts.authored_as; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(authored_as) ON TABLE public.posts TO authenticated;
GRANT SELECT(authored_as) ON TABLE public.posts TO anon;


--
-- Name: TABLE reviews; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.reviews TO anon;
GRANT ALL ON TABLE public.reviews TO authenticated;
GRANT ALL ON TABLE public.reviews TO service_role;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT MAINTAIN ON TABLE public.users TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.users TO authenticated;
GRANT ALL ON TABLE public.users TO service_role;


--
-- Name: COLUMN users.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.users TO anon;
GRANT SELECT(id) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.nickname; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(nickname) ON TABLE public.users TO anon;
GRANT SELECT(nickname),UPDATE(nickname) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.user_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(user_type) ON TABLE public.users TO anon;
GRANT SELECT(user_type) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.address; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(address) ON TABLE public.users TO anon;
GRANT SELECT(address) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.is_location_verified; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(is_location_verified) ON TABLE public.users TO anon;
GRANT SELECT(is_location_verified) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.last_verified_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(last_verified_at) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.profile_image_url; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(profile_image_url) ON TABLE public.users TO anon;
GRANT SELECT(profile_image_url),UPDATE(profile_image_url) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.profile_image_thumbnail_url; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(profile_image_thumbnail_url) ON TABLE public.users TO anon;
GRANT SELECT(profile_image_thumbnail_url),UPDATE(profile_image_thumbnail_url) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.profile_image_mime_type; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(profile_image_mime_type) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.profile_image_file_size; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(profile_image_file_size) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.push_enabled; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(push_enabled) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.users TO anon;
GRANT SELECT(created_at) ON TABLE public.users TO authenticated;


--
-- Name: COLUMN users.active_mode; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(active_mode) ON TABLE public.users TO authenticated;


--
-- Name: TABLE public_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.public_profiles TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.public_profiles TO authenticated;
GRANT ALL ON TABLE public.public_profiles TO service_role;


--
-- Name: TABLE reports; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.reports TO anon;
GRANT ALL ON TABLE public.reports TO authenticated;
GRANT ALL ON TABLE public.reports TO service_role;


--
-- Name: TABLE review_category_counts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.review_category_counts TO anon;
GRANT ALL ON TABLE public.review_category_counts TO authenticated;
GRANT ALL ON TABLE public.review_category_counts TO service_role;


--
-- Name: TABLE user_blocks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.user_blocks TO anon;
GRANT ALL ON TABLE public.user_blocks TO authenticated;
GRANT ALL ON TABLE public.user_blocks TO service_role;


--
-- Name: TABLE v_chat_rooms; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.v_chat_rooms TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.v_chat_rooms TO authenticated;
GRANT ALL ON TABLE public.v_chat_rooms TO service_role;


--
-- Name: TABLE v_comment_feed; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.v_comment_feed TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.v_comment_feed TO authenticated;
GRANT ALL ON TABLE public.v_comment_feed TO service_role;


--
-- Name: TABLE v_facility_review_comment_feed; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.v_facility_review_comment_feed TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.v_facility_review_comment_feed TO authenticated;
GRANT ALL ON TABLE public.v_facility_review_comment_feed TO service_role;


--
-- Name: TABLE v_pawing; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.v_pawing TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.v_pawing TO authenticated;
GRANT ALL ON TABLE public.v_pawing TO service_role;


--
-- Name: TABLE v_pawmate; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.v_pawmate TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.v_pawmate TO authenticated;
GRANT ALL ON TABLE public.v_pawmate TO service_role;


--
-- Name: TABLE v_post_feed; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.v_post_feed TO anon;
GRANT SELECT,MAINTAIN ON TABLE public.v_post_feed TO authenticated;
GRANT ALL ON TABLE public.v_post_feed TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- PostgreSQL database dump complete
--


