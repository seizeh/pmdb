-- 참여 알림 3종: 게시글 하트(post_heart) · 포잉(pawing_follow) ·
-- 포잉한 사람의 새 글(pawing_new_post 실구현)
--
-- 설계 — **지연 발송(유예 90초)**: 하트/포잉/새 글 시점에 알림을 만들지 않고
-- 분당 스윕(engagement-sweep)이 "90초 이상 경과 + 여전히 유효(취소 안 됨)"인
-- 행에만 알림을 생성한다. 누르고 바로 취소하는 레이스는 알림 자체가 생성되지
-- 않아 푸시·인앱 모두 조용하다. 같은 대상 재하트/재포잉은 평생 1회만 알림
-- (dedupe). 유예를 넘겨 발송된 뒤 취소하면 **미읽음 알림은 회수**(삭제).
--
-- 부수 수정: notifications unread 카운터 트리거에 DELETE 분기 추가 —
-- 하드삭제 시 카운터 미감소 드리프트(기존 알려진 문제, 알림함 삭제에도 해당) 해결.

-- ── 타입 확장 ────────────────────────────────────────────────────────────
alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (((notification_type)::text = any (array[
    'chat_message'::text, 'post_application'::text, 'post_comment'::text,
    'pawing_new_post'::text, 'application_accepted'::text,
    'application_accepted_by_co'::text, 'review_received'::text,
    'guardian_invite'::text, 'system_notice'::text, 'location_expired'::text,
    'chat_read_receipt'::text, 'unread_sync'::text, 'security_login'::text,
    'schedule_changed'::text, 'business_approved'::text, 'business_rejected'::text,
    'review_comment'::text, 'post_heart'::text, 'pawing_follow'::text])));

alter table public.notifications drop constraint notifications_resource_type_check;
alter table public.notifications add constraint notifications_resource_type_check
  check ((resource_type is null) or ((resource_type)::text = any (array[
    'post'::text, 'comment'::text, 'chat_room'::text, 'appointment'::text,
    'facility_review'::text, 'user'::text])));

-- ── 발송 추적 컬럼 ───────────────────────────────────────────────────────
alter table public.post_hearts add column if not exists notified boolean not null default false;
alter table public.pawings add column if not exists notified boolean not null default false;
alter table public.posts add column if not exists pawing_notified boolean not null default false;
create index if not exists post_hearts_unnotified_idx on public.post_hearts (created_at) where not notified;
create index if not exists pawings_unnotified_idx on public.pawings (created_at) where not notified;
create index if not exists posts_unnotified_idx on public.posts (created_at) where not pawing_notified;

-- ── 분당 스윕: 유예 지난 유효 참여를 알림으로 ───────────────────────────
create or replace function app.dispatch_engagement_notifications()
returns void
language plpgsql security definer set search_path to ''
as $$
declare v_grace interval := interval '90 seconds';
begin
  -- ① 게시글 하트 → 글 작성자에게 (자기 글 하트 제외, 글·작성자 기준 평생 1회)
  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select p.user_id, h.user_id, 'post_heart',
         u.nickname || '님이 회원님의 게시글을 좋아해요', p.title, 'post', p.id
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

  -- ② 포잉 → 팔로우받은 사람에게 (쌍 기준 평생 1회, 탭하면 상대 프로필로)
  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, resource_type, resource_id)
  select w.following_id, w.follower_id, 'pawing_follow',
         u.nickname || '님이 회원님을 Pawing 하기 시작했어요', 'user', w.follower_id
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

  -- ③ 포잉한 사람의 새 글 → 작성자의 팔로워 전원에게
  --    (업체 모드 글은 상호로 표기 — 개인 얼굴과 연결하지 않는다)
  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select w.follower_id, p.user_id, 'pawing_new_post',
         case when p.authored_as = 'business'
              then coalesce(bp.business_name, u.nickname)
              else u.nickname end || '님이 새 게시글을 올렸어요',
         p.title, 'post', p.id
    from public.posts p
    join public.users u on u.id = p.user_id
    left join public.business_profiles bp
      on bp.user_id = p.user_id and bp.status = 'approved'
    join public.pawings w on w.following_id = p.user_id
   where not p.pawing_notified
     and p.created_at <= now() - v_grace
     and p.deleted_at is null
     and w.follower_id <> p.user_id
     and not exists (
       select 1 from public.notifications n
        where n.notification_type = 'pawing_new_post'
          and n.user_id = w.follower_id and n.resource_id = p.id);
  update public.posts set pawing_notified = true
   where not pawing_notified and created_at <= now() - v_grace;
end;
$$;

-- ── 취소 회수: 유예를 넘겨 발송된 뒤 취소하면 미읽음 알림 삭제 ──────────
create or replace function app.tg_post_hearts_recall()
returns trigger
language plpgsql security definer set search_path to ''
as $$
begin
  delete from public.notifications
   where notification_type = 'post_heart'
     and actor_user_id = old.user_id
     and resource_id = old.post_id
     and is_read = false;
  return old;
end;
$$;
drop trigger if exists trg_post_hearts_recall on public.post_hearts;
create trigger trg_post_hearts_recall
  after delete on public.post_hearts
  for each row execute function app.tg_post_hearts_recall();

create or replace function app.tg_pawings_recall()
returns trigger
language plpgsql security definer set search_path to ''
as $$
begin
  delete from public.notifications
   where notification_type = 'pawing_follow'
     and user_id = old.following_id
     and actor_user_id = old.follower_id
     and is_read = false;
  return old;
end;
$$;
drop trigger if exists trg_pawings_recall on public.pawings;
create trigger trg_pawings_recall
  after delete on public.pawings
  for each row execute function app.tg_pawings_recall();

-- ── unread 카운터 DELETE 분기 — 하드삭제 드리프트 해결(알림함 삭제 포함) ─
create or replace function app.tg_notifications_unread_count()
returns trigger
language plpgsql security definer set search_path to ''
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
drop trigger if exists trg_notifications_unread_count on public.notifications;
create trigger trg_notifications_unread_count
  after insert or update or delete on public.notifications
  for each row execute function app.tg_notifications_unread_count();

-- ── 분당 스윕 등록 ───────────────────────────────────────────────────────
select cron.schedule('engagement-sweep', '* * * * *',
  'select app.dispatch_engagement_notifications();');
