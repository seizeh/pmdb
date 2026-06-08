-- 1) 로그인 검증: username/password 일치 + active 인 사용자만 반환.
--    SECURITY DEFINER + service_role 전용 (Edge Function login 에서만 호출).
create or replace function public.login_user(p_username text, p_password text)
returns table(id uuid, nickname text, user_type text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return query
  select u.id, u.nickname::text, u.user_type::text
  from public.users u
  where lower(u.username) = lower(p_username)
    and u.status = 'active'
    and u.password_hash = extensions.crypt(p_password, u.password_hash);
end;
$$;

revoke all on function public.login_user(text, text) from public;
revoke all on function public.login_user(text, text) from anon;
revoke all on function public.login_user(text, text) from authenticated;
grant execute on function public.login_user(text, text) to service_role;

-- 2) 커뮤니티 피드 뷰: 게시글 + 작성자 닉네임 + 내가 하트했는지.
--    security_invoker → 호출자(anon/authenticated) RLS 적용, app.uid() 가 JWT sub 를 읽음.
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
  ) as hearted
from public.posts p
left join public.public_profiles pr on pr.id = p.user_id;

grant select on public.v_post_feed to anon, authenticated;

-- 3) 댓글 뷰: 미삭제 댓글 + 작성자 닉네임.
create or replace view public.v_comment_feed
with (security_invoker = true) as
select
  c.id,
  c.post_id,
  c.user_id,
  c.content,
  c.created_at,
  pr.nickname as author_nickname
from public.comments c
left join public.public_profiles pr on pr.id = c.user_id
where c.is_deleted = false;

grant select on public.v_comment_feed to anon, authenticated;
