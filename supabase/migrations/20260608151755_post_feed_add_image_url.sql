-- v_post_feed 에 image_url 추가 (컬럼을 끝에 추가 → CREATE OR REPLACE 허용).
create or replace view public.v_post_feed
with (security_invoker = true) as
select
  p.id,
  p.category,
  p.title,
  p.content,
  p.user_id,
  pr.nickname     as author_nickname,
  pr.user_type    as author_user_type,
  p.created_at,
  p.scheduled_at,
  p.display_address as location,
  p.heart_count,
  p.comment_count,
  p.view_count,
  p.progress_status,
  exists(
    select 1 from public.post_hearts h
    where h.post_id = p.id and h.user_id = app.uid()
  ) as hearted,
  p.image_url
from public.posts p
left join public.public_profiles pr on pr.id = p.user_id;
