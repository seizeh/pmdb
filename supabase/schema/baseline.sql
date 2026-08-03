--
-- baseline.sql — 마이그레이션 저장소 밖(out-of-band)에 있던 기반 스키마
--
-- 자동 생성물이다. 직접 수정하지 말고 ./scripts/build_baseline.py 를 다시 돌릴 것.
-- prelude.sql → baseline.sql → migrations/*.sql 순서로 적용하면
-- schema.sql 스냅샷과 같은 스키마가 나온다(CI replay 잡이 매번 검증).
--

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
-- Name: chat_block_blocked_user(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.chat_block_blocked_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if exists (
    select 1
    from public.chat_room_members m
    join public.user_blocks b
      on (b.blocker_id = new.sender_id and b.blocked_id = m.user_id)
      or (b.blocked_id = new.sender_id and b.blocker_id = m.user_id)
    where m.room_id = new.room_id
      and m.user_id <> new.sender_id
  ) then
    raise exception '차단된 상대와는 메시지를 주고받을 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;


--
-- Name: FUNCTION chat_block_blocked_user(); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.chat_block_blocked_user() IS '차단 관계(양방향)면 메시지 INSERT 차단 — App Store 1.2.';


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
-- Name: tg_comments_block_check(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_comments_block_check() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_owner uuid;
begin
  select p.user_id into v_owner from public.posts p where p.id = new.post_id;
  if v_owner is not null and app.is_blocked_pair(v_owner, new.user_id) then
    raise exception '차단한 사용자의 게시글에는 댓글을 쓸 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;


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
-- Name: tg_notifications_block_filter(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_notifications_block_filter() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.actor_user_id is not null
     and new.actor_user_id <> new.user_id
     and app.is_blocked_pair(new.user_id, new.actor_user_id)
  then
    return null; -- 행을 만들지 않는다(= 푸시도 배지도 없다)
  end if;
  return new;
end $$;


--
-- Name: FUNCTION tg_notifications_block_filter(); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.tg_notifications_block_filter() IS '차단 쌍 사이의 알림을 생성 단계에서 제거. 생산자 12개를 하나씩 고치는 대신 길목 한 곳.';


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
-- Name: tg_post_hearts_block_check(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_post_hearts_block_check() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_owner uuid;
begin
  select p.user_id into v_owner from public.posts p where p.id = new.post_id;
  if v_owner is not null and app.is_blocked_pair(v_owner, new.user_id) then
    raise exception '차단한 사용자의 게시글에는 반응할 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;


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
-- Name: tg_post_pets_bump_verify_count(); Type: FUNCTION; Schema: app; Owner: -
--

CREATE FUNCTION app.tg_post_pets_bump_verify_count() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  update public.pets
     set verify_post_count = verify_post_count + 1
   where id = new.pet_id
     and exists (
           select 1 from public.posts p
            where p.id = new.post_id
              and p.category in ('walk_together','walk_proxy','care','give_away'));
  return new;
end $$;


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
    -- 간이 후기 전용 토큰은 여기까지 오면 안 된다(signup-lite 가 lite=true 를 박는다).
    and coalesce(
      (nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'lite', '') <> 'true'
$$;


--
-- Name: FUNCTION uid(); Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON FUNCTION app.uid() IS '인증된 사용자 uuid. status=active + token_version 일치 + 간이(lite) 토큰이 아닐 것.';


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
-- Name: auth_logs; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.auth_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    ip_hash text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


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
-- Name: client_errors; Type: TABLE; Schema: app; Owner: -
--

CREATE TABLE app.client_errors (
    id bigint NOT NULL,
    user_id uuid,
    where_key character varying(80) NOT NULL,
    message character varying(500) NOT NULL,
    stack text,
    platform character varying(10),
    app_release character varying(40),
    extra jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT client_errors_stack_len CHECK (((stack IS NULL) OR (length(stack) <= 8000)))
);


--
-- Name: TABLE client_errors; Type: COMMENT; Schema: app; Owner: -
--

COMMENT ON TABLE app.client_errors IS '클라이언트 오류 리포팅(reported 등급만). 30일 보존 후 app.cleanup_retention 이 파기 (0031)';


--
-- Name: client_errors_id_seq; Type: SEQUENCE; Schema: app; Owner: -
--

ALTER TABLE app.client_errors ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME app.client_errors_id_seq
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
    CONSTRAINT appointments_completed_at_chk CHECK ((((status)::text <> 'completed'::text) OR (completed_at IS NOT NULL))),
    CONSTRAINT appointments_participants_distinct CHECK ((post_owner_id <> applicant_id)),
    CONSTRAINT appointments_status_check CHECK (((status)::text = ANY ((ARRAY['scheduled'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[])))
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
    CONSTRAINT chat_messages_image_file_size_check CHECK (((image_file_size IS NULL) OR (image_file_size <=
CASE
    WHEN ((image_mime_type)::text ~~ 'video/%'::text) THEN 104857600
    ELSE 10485760
END))),
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
    updated_at timestamp with time zone);


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
    created_at timestamp with time zone DEFAULT now() NOT NULL);


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
    CONSTRAINT device_tokens_platform_check CHECK (((platform)::text = ANY ((ARRAY['ios'::character varying, 'android'::character varying, 'web'::character varying])::text[])))
);


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
    CONSTRAINT notifications_notification_type_check CHECK (((notification_type)::text = ANY (ARRAY['chat_message'::text, 'post_application'::text, 'post_comment'::text, 'pawing_new_post'::text, 'application_accepted'::text, 'application_accepted_by_co'::text, 'review_received'::text, 'guardian_invite'::text, 'system_notice'::text, 'location_expired'::text, 'chat_read_receipt'::text, 'unread_sync'::text, 'security_login'::text, 'schedule_changed'::text, 'business_approved'::text, 'business_rejected'::text, 'review_comment'::text, 'post_heart'::text, 'pawing_follow'::text, 'facility_review_received'::text, 'pet_in_post'::text, 'vaccine_reminder'::text]))),
    CONSTRAINT notifications_priority_check CHECK (((priority)::text = ANY ((ARRAY['high'::character varying, 'normal'::character varying, 'low'::character varying])::text[]))),
    CONSTRAINT notifications_push_attempts_check CHECK ((push_attempts >= 0)),
    CONSTRAINT notifications_push_status_check CHECK (((push_status)::text = ANY (ARRAY['pending'::text, 'sending'::text, 'sent'::text, 'failed'::text, 'skipped'::text]))),
    CONSTRAINT notifications_resource_type_check CHECK (((resource_type IS NULL) OR ((resource_type)::text = ANY (ARRAY['post'::text, 'comment'::text, 'chat_room'::text, 'appointment'::text, 'facility_review'::text, 'user'::text, 'pet'::text]))))
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
    CONSTRAINT pets_gender_check CHECK (((gender IS NULL) OR ((gender)::text = ANY ((ARRAY['male'::character varying, 'female'::character varying])::text[])))),
    CONSTRAINT pets_pet_status_check CHECK (((pet_status)::text = ANY ((ARRAY['active'::character varying, 'transferred'::character varying, 'deceased'::character varying, 'deleted'::character varying])::text[]))));


--
-- Name: TABLE pets; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pets IS 'pet_status 로 soft delete. 과거 게시글·평가 FK 참조 보존';


--
-- Name: COLUMN pets.primary_guardian_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pets.primary_guardian_id IS '현재 소유자(owner) user_id. 소유권 이전 시 이 값 변경. 전체 보호자는 pet_guardians 참조';


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
    CONSTRAINT phone_verifications_purpose_check CHECK (((purpose)::text = ANY ((ARRAY['signup'::character varying, 'password_reset'::character varying, 'review'::character varying])::text[])))
);


--
-- Name: TABLE phone_verifications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.phone_verifications IS '전화 인증/비번재설정 코드(6자리·5분). rate limit: 동일 번호 1분당 1회(서비스/엣지)';


--
-- Name: post_hearts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_hearts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL);


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
-- Name: TABLE post_pets; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.post_pets IS '게시글↔펫 연결. 쓰기는 create_post_verified(definer) 전용 — 직접 INSERT 는 pets.verify_post_count 를 부풀려 사진 인증 게이트를 우회시킨다(20260803182000).';


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
    CONSTRAINT posts_category_check CHECK (((category)::text = ANY (ARRAY['walk_together'::text, 'walk_proxy'::text, 'care'::text, 'adoption'::text, 'give_away'::text, 'free'::text, 'news'::text]))),
    CONSTRAINT posts_comment_count_check CHECK ((comment_count >= 0)),
    CONSTRAINT posts_deleted_at_consistency CHECK ((((visibility_status)::text !~~ 'deleted_%'::text) OR (deleted_at IS NOT NULL))),
    CONSTRAINT posts_image_file_size_check CHECK (((image_file_size IS NULL) OR (image_file_size <=
CASE
    WHEN ((image_mime_type)::text ~~ 'video/%'::text) THEN 104857600
    ELSE 12582912
END))),
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
    CONSTRAINT users_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying, 'suspended'::character varying, 'deleted'::character varying, 'lite'::character varying])::text[]))),
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
-- Name: COLUMN users.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.status IS 'active=정식 회원 · lite=후기 전용 간이 회원(비회원 취급, app.uid() 에서 제외) · inactive=휴면 · suspended=정지 · deleted=탈퇴';


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
-- Name: auth_logs auth_logs_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.auth_logs
    ADD CONSTRAINT auth_logs_pkey PRIMARY KEY (id);


--
-- Name: business_purge_config business_purge_config_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.business_purge_config
    ADD CONSTRAINT business_purge_config_pkey PRIMARY KEY (id);


--
-- Name: client_errors client_errors_pkey; Type: CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.client_errors
    ADD CONSTRAINT client_errors_pkey PRIMARY KEY (id);


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
-- Name: client_errors_recent_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX client_errors_recent_idx ON app.client_errors USING btree (created_at DESC);


--
-- Name: client_errors_where_idx; Type: INDEX; Schema: app; Owner: -
--

CREATE INDEX client_errors_where_idx ON app.client_errors USING btree (where_key, created_at DESC);


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
-- Name: user_blocks_blocked_blocker_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_blocks_blocked_blocker_idx ON public.user_blocks USING btree (blocked_id, blocker_id);


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
-- Name: users_user_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_user_type_idx ON public.users USING btree (user_type);


--
-- Name: chat_messages chat_messages_block_blocked; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER chat_messages_block_blocked BEFORE INSERT ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION app.chat_block_blocked_user();


--
-- Name: location_verifications log_location_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER log_location_usage AFTER INSERT ON public.location_verifications FOR EACH ROW EXECUTE FUNCTION app.tg_log_location_usage('활동지역 인증(GPS 검증)');


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
-- Name: comments trg_comments_block_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_comments_block_check BEFORE INSERT ON public.comments FOR EACH ROW EXECUTE FUNCTION app.tg_comments_block_check();


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
-- Name: notification_preferences trg_notification_preferences_upd; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notification_preferences_upd BEFORE UPDATE ON public.notification_preferences FOR EACH ROW EXECUTE FUNCTION app.tg_set_updated_at();


--
-- Name: notifications trg_notifications_block_filter; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notifications_block_filter BEFORE INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION app.tg_notifications_block_filter();


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
-- Name: pet_guardian_invites trg_notify_guardian_invite; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_guardian_invite AFTER INSERT ON public.pet_guardian_invites FOR EACH ROW EXECUTE FUNCTION app.tg_notify_guardian_invite();


--
-- Name: post_pets trg_notify_pet_in_post; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_pet_in_post AFTER INSERT ON public.post_pets FOR EACH ROW EXECUTE FUNCTION app.tg_notify_pet_in_post();


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
-- Name: post_hearts trg_post_hearts_block_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_hearts_block_check BEFORE INSERT ON public.post_hearts FOR EACH ROW EXECUTE FUNCTION app.tg_post_hearts_block_check();


--
-- Name: post_hearts trg_post_hearts_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_hearts_count AFTER INSERT OR DELETE ON public.post_hearts FOR EACH ROW EXECUTE FUNCTION app.tg_post_hearts_count();


--
-- Name: post_hearts trg_post_hearts_recall; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_hearts_recall AFTER DELETE ON public.post_hearts FOR EACH ROW EXECUTE FUNCTION app.tg_post_hearts_recall();


--
-- Name: post_pets trg_post_pets_bump_verify_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_post_pets_bump_verify_count AFTER INSERT ON public.post_pets FOR EACH ROW EXECUTE FUNCTION app.tg_post_pets_bump_verify_count();


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
-- Name: client_errors client_errors_user_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: -
--

ALTER TABLE ONLY app.client_errors
    ADD CONSTRAINT client_errors_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


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
-- Name: pets pets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pets
    ADD CONSTRAINT pets_user_id_fkey FOREIGN KEY (primary_guardian_id) REFERENCES public.users(id);


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
-- Name: business_purge_config; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.business_purge_config ENABLE ROW LEVEL SECURITY;

--
-- Name: client_errors; Type: ROW SECURITY; Schema: app; Owner: -
--

ALTER TABLE app.client_errors ENABLE ROW LEVEL SECURITY;

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
-- Name: facility_cache; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.facility_cache ENABLE ROW LEVEL SECURITY;

--
-- Name: facility_cache facility_cache_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY facility_cache_select ON public.facility_cache FOR SELECT USING (true);


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
-- Name: FUNCTION facility_sibling_ids(p_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.facility_sibling_ids(p_id uuid) TO anon;
GRANT ALL ON FUNCTION public.facility_sibling_ids(p_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.facility_sibling_ids(p_id uuid) TO service_role;


--
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.rls_auto_enable() TO service_role;


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
-- Name: TABLE device_tokens; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.device_tokens TO anon;
GRANT ALL ON TABLE public.device_tokens TO authenticated;
GRANT ALL ON TABLE public.device_tokens TO service_role;


--
-- Name: TABLE facility_cache; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.facility_cache TO anon;
GRANT ALL ON TABLE public.facility_cache TO authenticated;
GRANT ALL ON TABLE public.facility_cache TO service_role;


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
-- Name: TABLE phone_verifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.phone_verifications TO anon;
GRANT ALL ON TABLE public.phone_verifications TO authenticated;
GRANT ALL ON TABLE public.phone_verifications TO service_role;


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
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE public.post_pets TO authenticated;
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



--
-- 여기부터는 baseline-manual.sql — 스냅샷에서 역산할 수 없어
-- 손으로 복원한 조각이다(이유는 그 파일 주석 참고).
--

-- 베이스라인의 수기 복원 조각 — build_baseline.py 가 생성한 baseline.sql 끝에 붙는다.
--
-- 스냅샷에서 기계적으로 역산할 수 없는 것만 여기 둔다. 지금은 한 가지다:
--
--   public_profiles 뷰는 기반 스키마에 있었는데, 20260610120125 가
--   `drop view … cascade` 후 다시 만든다(아이디 비공개화). 그래서
--   ① 그 이전 마이그레이션 5개가 이 뷰를 참조하고
--   ② 스냅샷의 최종 정의는 한참 뒤에 생기는 business_profiles 에 의존한다.
--   최종 정의를 베이스라인에 둘 수도, 빼버릴 수도 없으므로 재생성 이전 형태를
--   복원해 둔다. 어차피 20260610120125 가 통째로 갈아치우므로, 그 앞 마이그레이션이
--   쓰는 컬럼(id·nickname·user_type)만 맞으면 된다.
--
-- 리플레이 결과가 스냅샷과 일치하는지는 CI 의 replay 잡이 검증한다.

CREATE VIEW public.public_profiles AS
 SELECT u.id,
    u.nickname,
    u.user_type,
    u.profile_image_url,
    u.address,
    u.is_location_verified,
    u.created_at
   FROM public.users u;

GRANT SELECT ON TABLE public.public_profiles TO anon;
GRANT SELECT ON TABLE public.public_profiles TO authenticated;


-- pawings_uq — 20260717010000 이 `drop constraint pawings_uq`(IF EXISTS 없음) 로 시작한다.
-- 그 제약은 기반 스키마에 (follower_id, following_id) 2컬럼으로 있었고, 마이그레이션이
-- context 를 넣은 3컬럼으로 바꾼다(두 얼굴 독립 팔로우). context 컬럼 자체도
-- 마이그레이션이 붙이므로 베이스라인에는 2컬럼 형태가 있어야 drop 이 성립한다.
ALTER TABLE ONLY public.pawings
    ADD CONSTRAINT pawings_uq UNIQUE (follower_id, following_id);
