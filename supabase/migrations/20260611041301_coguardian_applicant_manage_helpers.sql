-- 공동보호자가 다른 보호자의 게시글 지원자를 관리(조회·수락)할 수 있게 하는 기반.
-- is_post_manager: 작성자 ∪ 게시글 펫의 보호자(owner/co_guardian) ∪ admin.
-- can_manage_post_applicants: 앱 버튼 분기용 RPC(지원자 목록 보기 vs 지원하기).

create or replace function app.is_post_manager(p_post uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
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

create or replace function public.can_manage_post_applicants(p_post uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select app.is_post_manager(p_post)
$$;

grant execute on function public.can_manage_post_applicants(uuid) to anon, authenticated;
