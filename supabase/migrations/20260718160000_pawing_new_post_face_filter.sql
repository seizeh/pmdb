-- pawing_new_post 얼굴 필터 복원.
-- 20260717010000(pawing_dual_face)이 넣은 "글의 얼굴(authored_as)과 같은 얼굴
-- 팔로워에게만 발송" 조건이, 병렬 작업(20260717150000 engagement_notifications →
-- 20260718 pet_in_post 억제)의 함수 재정의 과정에서 유실됐다 — 업체 소식이
-- 개인 팔로워에게도 갈 수 있는 상태. 최신 정의(이모지 타이틀·notif_trunc·
-- pet_in_post 우선 억제)를 유지한 채 조인 조건만 복원한다.

create or replace function app.dispatch_engagement_notifications()
returns void
language plpgsql security definer set search_path to ''
as $function$
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
                         and w.context = p.authored_as  -- 같은 얼굴 팔로워만
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
$function$;
