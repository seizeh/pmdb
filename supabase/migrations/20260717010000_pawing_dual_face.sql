-- 두 얼굴(개인/업체) 독립 팔로우 (0025 후속).
-- 기존 (follower, following) 유니크 때문에 같은 사용자의 업체 얼굴을 팔로우하면
-- 개인 팔로우 행과 충돌(하나로 합쳐짐)했다 → context 포함 유니크로 변경해
-- 개인·업체 팔로우가 공존하게 한다.
-- 새 글 알림(pawing_new_post)도 글의 얼굴(authored_as)과 같은 얼굴을 팔로우한
-- 사람에게만 발송(업체 소식은 업체 팔로워에게, 개인 글은 개인 팔로워에게).

alter table public.pawings drop constraint pawings_uq;
alter table public.pawings add constraint pawings_uq
  unique (follower_id, following_id, context);

create or replace function app.dispatch_engagement_notifications()
returns void
language plpgsql security definer set search_path to ''
as $function$
declare v_grace interval := interval '90 seconds';
begin
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
                         and w.context = p.authored_as  -- 같은 얼굴 팔로워만
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
$function$;

-- v_pawmate: 한 사람이 내 두 얼굴을 모두 팔로우하면 목록에 중복 행 — 최근 팔로우
-- 기준 1행으로 접는다.
create or replace view public.v_pawmate with (security_invoker = true) as
 select distinct on (pr.id)
        pr.id as user_id,
        pr.nickname,
        pr.user_type,
        p.created_at,
        (exists ( select 1 from public.pawings me
                   where me.follower_id = app.uid()
                     and me.following_id = p.follower_id)) as i_follow_back,
        pr.profile_image_url
   from public.pawings p
     join public.public_profiles pr on pr.id = p.follower_id
  where p.following_id = app.uid()
  order by pr.id, p.created_at desc;
