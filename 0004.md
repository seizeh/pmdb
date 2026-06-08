-- ============================================================================
-- PawMate · 0004 · Triggers & Functions (business logic / 정합성 안전망)
-- Supabase / PostgreSQL 15 · MVP
-- ----------------------------------------------------------------------------
-- 원칙: 상태전이·권한·동시성은 "앱(서비스) + DB trigger" 2중 방어.
--       cross-row 갱신 함수는 SECURITY DEFINER + search_path='' 로 RLS 우회.
-- ============================================================================

-- ===========================================================================
-- A. updated_at 자동 갱신 (updated_at 컬럼이 있는 테이블 전부)
-- ===========================================================================
create trigger trg_users_updated                before update on public.users                   for each row execute function app.tg_set_updated_at();
create trigger trg_pets_updated                 before update on public.pets                    for each row execute function app.tg_set_updated_at();
create trigger trg_business_profiles_updated     before update on public.business_profiles        for each row execute function app.tg_set_updated_at();
create trigger trg_posts_updated                 before update on public.posts                   for each row execute function app.tg_set_updated_at();
create trigger trg_applications_updated          before update on public.applications             for each row execute function app.tg_set_updated_at();
create trigger trg_appointments_updated          before update on public.appointments             for each row execute function app.tg_set_updated_at();
create trigger trg_chat_messages_updated         before update on public.chat_messages            for each row execute function app.tg_set_updated_at();
create trigger trg_chat_room_members_updated     before update on public.chat_room_members        for each row execute function app.tg_set_updated_at();
create trigger trg_notifications_updated         before update on public.notifications            for each row execute function app.tg_set_updated_at();
create trigger trg_device_tokens_updated         before update on public.device_tokens            for each row execute function app.tg_set_updated_at();
create trigger trg_notification_preferences_upd  before update on public.notification_preferences for each row execute function app.tg_set_updated_at();
create trigger trg_reports_updated               before update on public.reports                 for each row execute function app.tg_set_updated_at();
create trigger trg_review_category_counts_upd    before update on public.review_category_counts   for each row execute function app.tg_set_updated_at();

-- ===========================================================================
-- B. posts : deleted_at 동기화 + 상태전이 검증
-- ===========================================================================

-- B-1. deleted_at 자동 세팅(INSERT/UPDATE 공통)
create or replace function app.tg_posts_deleted_at()
returns trigger
language plpgsql
set search_path = ''
as $$
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
create trigger trg_posts_deleted_at
  before insert or update on public.posts
  for each row execute function app.tg_posts_deleted_at();

-- B-2. 상태전이 매트릭스 검증(문서 14-1)
create or replace function app.tg_posts_validate_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
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
create trigger trg_posts_validate_transition
  before update on public.posts
  for each row execute function app.tg_posts_validate_transition();

-- B-3. 작성 권한(카테고리별) + 카테고리별 약속일정 규칙
create or replace function app.tg_posts_check_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_type   text;
  v_active_pets int;
begin
  select user_type into v_user_type from public.users where id = new.user_id;
  if v_user_type is null then
    raise exception 'posts: 존재하지 않는 작성자';
  end if;

  -- 동반산책/대리산책/돌봄/분양: pet_owner + active pet 1마리 이상
  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if v_user_type <> 'pet_owner' then
      raise exception 'posts: % 카테고리는 pet_owner 만 작성 가능', new.category;
    end if;
    select count(*) into v_active_pets
      from public.pets where user_id = new.user_id and pet_status = 'active';
    if v_active_pets < 1 then
      raise exception 'posts: % 카테고리는 활성 반려동물 1마리 이상 필요', new.category;
    end if;
  end if;

  -- 동반/대리산책·돌봄: 약속 일정 필수
  if new.category in ('walk_together','walk_proxy','care') and new.scheduled_at is null then
    raise exception 'posts: % 카테고리는 약속 일정(scheduled_at) 필수', new.category;
  end if;

  -- 분양/입양: 게시 시 약속 일정 없음(수락 후 설정)
  if new.category in ('give_away','adoption') and new.scheduled_at is not null then
    raise exception 'posts: % 카테고리는 게시 시 약속 일정을 둘 수 없음', new.category;
  end if;

  return new;
end;
$$;
create trigger trg_posts_check_write
  before insert on public.posts
  for each row execute function app.tg_posts_check_write();

-- ===========================================================================
-- C. post_pets : 분양(give_away)은 1행만
-- ===========================================================================
create or replace function app.tg_post_pets_giveaway_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text;
  v_existing int;
begin
  select category into v_category from public.posts where id = new.post_id;
  if v_category = 'give_away' then
    select count(*) into v_existing from public.post_pets where post_id = new.post_id;
    if v_existing >= 1 then
      raise exception 'post_pets: 분양 게시글은 반려동물 1마리만 연결 가능';
    end if;
  end if;
  return new;
end;
$$;
create trigger trg_post_pets_giveaway_limit
  before insert on public.post_pets
  for each row execute function app.tg_post_pets_giveaway_limit();

-- ===========================================================================
-- D. post_likes : like_count 캐시 동기화
-- ===========================================================================
create or replace function app.tg_post_likes_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set like_count = like_count + 1 where id = new.post_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.posts set like_count = greatest(like_count - 1, 0) where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;
create trigger trg_post_likes_count
  after insert or delete on public.post_likes
  for each row execute function app.tg_post_likes_count();

-- ===========================================================================
-- E. post_views : view_count 캐시 (ON CONFLICT DO NOTHING → 성공 INSERT 만 트리거)
-- ===========================================================================
create or replace function app.tg_post_views_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.posts set view_count = view_count + 1 where id = new.post_id;
  return new;
end;
$$;
create trigger trg_post_views_count
  after insert on public.post_views
  for each row execute function app.tg_post_views_count();

-- ===========================================================================
-- F. comments : comment_count 캐시 동기화 (soft delete 반영)
-- ===========================================================================
create or replace function app.tg_comments_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
-- comment_count 는 AFTER 로 동기화. deleted_at 세팅은 BEFORE 트리거에서 처리(아래)
create or replace function app.tg_comments_soft_delete_ts()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.is_deleted = false and new.is_deleted = true and new.deleted_at is null then
    new.deleted_at := now();
  end if;
  return new;
end;
$$;
create trigger trg_comments_soft_delete_ts
  before update on public.comments
  for each row execute function app.tg_comments_soft_delete_ts();
create trigger trg_comments_count
  after insert or update on public.comments
  for each row execute function app.tg_comments_count();

-- ===========================================================================
-- G. applications : 지원 차단(INSERT) + 수락(UPDATE)→약속 생성
-- ===========================================================================

-- G-1. BEFORE INSERT: 모집중 아닌/삭제된 게시글 차단 + 본인 게시글 자기지원 차단
create or replace function app.tg_applications_block_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner   uuid;
  v_prog    text;
  v_vis     text;
begin
  select user_id, progress_status, visibility_status
    into v_owner, v_prog, v_vis
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

  return new;
end;
$$;
create trigger trg_applications_block_insert
  before insert on public.applications
  for each row execute function app.tg_applications_block_insert();

-- G-2. AFTER UPDATE: status pending→accepted 시 약속 생성(이중 수락 방어)
create or replace function app.tg_applications_on_accept()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_post        public.posts%rowtype;
  v_locked_id   uuid;
begin
  if not (old.status = 'pending' and new.status = 'accepted') then
    return new;
  end if;

  -- 게시글 row lock (동시 수락 직렬화)
  select * into v_post from public.posts where id = new.post_id for update;
  if v_post.id is null then
    raise exception 'applications: 게시글이 존재하지 않습니다';
  end if;

  -- recruiting → matched (한 명만 성공)
  update public.posts
     set progress_status = 'matched'
   where id = new.post_id and progress_status = 'recruiting'
  returning id into v_locked_id;

  if v_locked_id is null then
    raise exception '다른 사용자가 먼저 수락하였습니다';
  end if;

  -- 약속 생성 (활성 약속 1개 partial unique 가 최종 안전망)
  insert into public.appointments
    (application_id, post_id, post_owner_id, applicant_id, status, scheduled_at)
  values
    (new.id, new.post_id, v_post.user_id, new.applicant_id, 'scheduled', v_post.scheduled_at);

  return new;
end;
$$;
create trigger trg_applications_on_accept
  after update on public.applications
  for each row execute function app.tg_applications_on_accept();

-- ===========================================================================
-- H. appointments : 상태전이 + completed_at + posts 동기화
-- ===========================================================================

-- H-1. BEFORE UPDATE: 전이 검증 + completed_at 세팅
create or replace function app.tg_appointments_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
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
create trigger trg_appointments_before_update
  before update on public.appointments
  for each row execute function app.tg_appointments_before_update();

-- H-2. AFTER UPDATE: posts.progress_status 동기화 + 연결 application 동기화
create or replace function app.tg_appointments_after_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'scheduled' and new.status = 'completed' then
    -- 게시글 완료 동기화 (matched → completed)
    update public.posts
       set progress_status = 'completed'
     where id = new.post_id and progress_status = 'matched';
    -- 연결 지원 accepted → completed
    update public.applications
       set status = 'completed'
     where id = new.application_id and status = 'accepted';

  elsif old.status = 'scheduled' and new.status = 'cancelled' then
    -- 약속 취소 → 게시글 재모집(matched → recruiting). 취소된 약속 행은 보존.
    update public.posts
       set progress_status = 'recruiting'
     where id = new.post_id and progress_status = 'matched';
    -- 연결 지원 accepted → cancelled
    update public.applications
       set status = 'cancelled'
     where id = new.application_id and status = 'accepted';
  end if;

  return new;
end;
$$;
create trigger trg_appointments_after_update
  after update on public.appointments
  for each row execute function app.tg_appointments_after_update();

-- ===========================================================================
-- I. reviews : 당사자/완료 검증 + 카테고리 중복 차단 + 집계
-- ===========================================================================

-- I-1. BEFORE INSERT: completed 약속 당사자만, 중복 카테고리 차단
create or replace function app.tg_reviews_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
create trigger trg_reviews_validate
  before insert on public.reviews
  for each row execute function app.tg_reviews_validate();

-- I-2. AFTER INSERT: review_category_counts 집계(+1)
create or replace function app.tg_reviews_aggregate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
create trigger trg_reviews_aggregate
  after insert on public.reviews
  for each row execute function app.tg_reviews_aggregate();

-- ===========================================================================
-- J. chat_messages : last_message 갱신 + unread_chat_count
-- ===========================================================================

-- J-1. AFTER INSERT: 방 last_message_* 갱신 + 발신자 외 멤버 unread +1
create or replace function app.tg_chat_messages_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_preview text;
begin
  if new.content is not null then
    v_preview := left(new.content, 100);
  else
    v_preview := '[사진]';
  end if;

  update public.chat_rooms
     set last_message_id      = new.id,
         last_message_at      = new.created_at,
         last_message_preview = v_preview
   where id = new.room_id;

  -- 발신자 제외 멤버 미읽음 +1
  update public.users u
     set unread_chat_count = unread_chat_count + 1
    from public.chat_room_members m
   where m.room_id = new.room_id
     and m.user_id = u.id
     and m.user_id <> new.sender_id;

  return new;
end;
$$;
create trigger trg_chat_messages_after_insert
  after insert on public.chat_messages
  for each row execute function app.tg_chat_messages_after_insert();

-- J-2. BEFORE UPDATE: soft delete 시각 세팅
create or replace function app.tg_chat_messages_soft_delete_ts()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.is_deleted = false and new.is_deleted = true and new.deleted_at is null then
    new.deleted_at := now();
  end if;
  return new;
end;
$$;
create trigger trg_chat_messages_soft_delete_ts
  before update on public.chat_messages
  for each row execute function app.tg_chat_messages_soft_delete_ts();

-- J-3. AFTER UPDATE: soft delete 된 메시지가 방의 마지막이면 preview 덮어쓰기
create or replace function app.tg_chat_messages_after_softdelete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.is_deleted = false and new.is_deleted = true then
    update public.chat_rooms
       set last_message_preview = '삭제된 메시지입니다.'
     where id = new.room_id and last_message_id = new.id;
  end if;
  return new;
end;
$$;
create trigger trg_chat_messages_after_softdelete
  after update on public.chat_messages
  for each row execute function app.tg_chat_messages_after_softdelete();

-- J-4. chat_room_members.last_read_message_id 갱신 시 unread 감소 + room 일치 검증
create or replace function app.tg_chat_members_read()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
create trigger trg_chat_members_read
  before update on public.chat_room_members
  for each row execute function app.tg_chat_members_read();

-- ===========================================================================
-- K. notifications : unread_notification_count 캐시
-- ===========================================================================
create or replace function app.tg_notifications_unread_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
  end if;
  return null;
end;
$$;
-- read_at 세팅은 BEFORE, 카운트는 AFTER 로 분리(정확성)
create or replace function app.tg_notifications_read_ts()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.is_read = false and new.is_read = true and new.read_at is null then
    new.read_at := now();
  end if;
  return new;
end;
$$;
create trigger trg_notifications_read_ts
  before update on public.notifications
  for each row execute function app.tg_notifications_read_ts();
create trigger trg_notifications_unread_count
  after insert or update on public.notifications
  for each row execute function app.tg_notifications_unread_count();

-- ===========================================================================
-- L. users : 가입 시 기본 provisioning (알림설정 + 관리자 문의방)
--    F-22: 사용자당 admin_inquiry 방 1개 (canonical_key='admin_'||user_id)
-- ===========================================================================
create or replace function app.tg_users_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room_id uuid;
begin
  -- 알림 설정 기본 행
  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  -- 관리자 문의 채팅방 (admin 계정 자신에게는 만들지 않음)
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

  return new;
end;
$$;
create trigger trg_users_after_insert
  after insert on public.users
  for each row execute function app.tg_users_after_insert();

-- ===========================================================================
-- M. admin audit log : 관리자 행위 자동 기록(민감 컬럼 제외)
--    posts(관리자 숨김/삭제), comments(관리자 삭제), reports(상태변경)
-- ===========================================================================
create or replace function app.tg_audit_posts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
create trigger trg_audit_posts
  after update on public.posts
  for each row execute function app.tg_audit_posts();

create or replace function app.tg_audit_comments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.is_admin() and old.is_deleted = false and new.is_deleted = true then
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(), 'delete_comment', 'comment', new.id,
            jsonb_build_object('post_id', new.post_id));
  end if;
  return new;
end;
$$;
create trigger trg_audit_comments
  after update on public.comments
  for each row execute function app.tg_audit_comments();

create or replace function app.tg_audit_reports()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.is_admin() and new.status is distinct from old.status then
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(), 'update_report_status', 'report', new.id,
            jsonb_build_object('before', old.status, 'after', new.status));
  end if;
  return new;
end;
$$;
create trigger trg_audit_reports
  after update on public.reports
  for each row execute function app.tg_audit_reports();
