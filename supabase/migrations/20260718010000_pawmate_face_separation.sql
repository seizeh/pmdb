-- Pawmate(나를 팔로우) 얼굴 분리 (0025 후속).
-- 한 사용자가 내 개인·업체 얼굴을 모두 팔로우하면 팔로워가 2명처럼 집계/표시됐다.
-- Pawmate 목록은 "지금 내 계정 모드(active_mode) 얼굴"의 팔로워만 보여준다 —
-- 개인 모드에선 개인 팔로워, 업체 모드에선 업체 팔로워(분리 원칙과 일치).
-- 카운트는 앱(profile_repository)이 같은 기준(context)으로 센다.

create or replace view public.v_pawmate with (security_invoker = true) as
 select pr.id as user_id,
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
    and p.context = coalesce(
          (select active_mode from public.users where id = app.uid()),
          'personal');
