-- pawing_new_post 억제 — 같은 게시글에 pet_in_post 가 이미 갔으면 중복 방지
--
-- pawing 중인 사람이 공동보호 펫을 게시글에 등록하면, 그 게시글로 안내하는
-- 알림이 둘 겹친다: pet_in_post(즉시) + pawing_new_post(90초 후). 공동보호자
-- 에게는 '내 펫이 올라감'(pet_in_post)이 더 구체적이므로 그쪽을 우선하고
-- pawing_new_post 는 억제. 스윕이 90초 후 돌 때 pet_in_post 는 이미 존재하므로
-- dedupe 조건에 pet_in_post 를 포함하기만 하면 된다.
--
-- (다른 두 삽입은 변경 없음 — 그대로 재선언.)

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
     -- 같은 수신자·게시글에 pawing_new_post(중복) 또는 pet_in_post(우선)가
     -- 이미 있으면 제외.
     and not exists (
       select 1 from public.notifications n
        where n.user_id = w.follower_id and n.resource_id = p.id
          and n.notification_type in ('pawing_new_post', 'pet_in_post'));
  update public.posts set pawing_notified = true
   where not pawing_notified and created_at <= now() - v_grace;
end;
$$;
