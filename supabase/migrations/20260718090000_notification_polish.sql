-- 알림 문구 다듬기 + 업체 방문 후기 알림 신설
--
-- ① 참여 알림(하트·포잉·새 글) 제목에 이모지, 본문(글 제목 등)은 60자 말줄임(…)
-- ② facility_review_received: 내 업체(형제 행 포함)에 방문 후기가 달리면 업주에게
--    알림 — 본문에 별점+후기 내용 미리보기. 후기 소프트 삭제 시 미읽음 회수.
--    (셀프 후기는 own_facility 게이트로 이미 차단돼 자기 알림 걱정 없음)

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
    'review_comment'::text, 'post_heart'::text, 'pawing_follow'::text,
    'facility_review_received'::text])));

-- ── 본문 말줄임 헬퍼 ─────────────────────────────────────────────────────
create or replace function app.notif_trunc(p_text text, p_max int default 60)
returns text
language sql immutable set search_path to ''
as $$
  select case
    when p_text is null then null
    when length(p_text) > p_max then left(p_text, p_max - 1) || '…'
    else p_text
  end;
$$;

-- ── 참여 알림 스윕: 이모지 + 말줄임 반영 ────────────────────────────────
create or replace function app.dispatch_engagement_notifications()
returns void
language plpgsql security definer set search_path to ''
as $$
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

-- ── 업체 방문 후기 알림: 후기 작성 즉시 업주(형제 행 포함)에게 ──────────
create or replace function app.tg_notify_facility_review()
returns trigger
language plpgsql security definer set search_path to ''
as $$
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
drop trigger if exists trg_notify_facility_review on public.facility_reviews;
create trigger trg_notify_facility_review
  after insert on public.facility_reviews
  for each row execute function app.tg_notify_facility_review();

-- 후기 소프트 삭제 시 미읽음 알림 회수.
create or replace function app.tg_facility_review_recall()
returns trigger
language plpgsql security definer set search_path to ''
as $$
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
drop trigger if exists trg_facility_review_recall on public.facility_reviews;
create trigger trg_facility_review_recall
  after update on public.facility_reviews
  for each row execute function app.tg_facility_review_recall();
