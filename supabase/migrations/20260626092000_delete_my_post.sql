-- 작성자 본인 게시글 소프트 삭제 RPC.
--
-- posts_update RLS 는 통과해도, 결과 행(visibility_status='deleted_by_user')이
-- posts_select 정책상 비가시라 직접 UPDATE 는 42501(new row violates RLS)로 막힌다.
-- → SECURITY DEFINER 로 RLS 를 우회하되, app.uid() 로 소유자만 허용한다.
-- 상태전이 트리거(tg_posts_validate_transition)가 visible→deleted_by_user 만 허용하므로
-- 이미 삭제/숨김 등 비정상 전이는 그대로 거절된다.

create or replace function public.delete_my_post(p_post uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_owner uuid; v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;
  select user_id into v_owner from public.posts where id = p_post;
  if v_owner is null then
    raise exception 'posts: 게시글을 찾을 수 없습니다';
  end if;
  if v_owner <> v_uid then
    raise exception 'posts: 본인 게시글만 삭제할 수 있습니다';
  end if;
  update public.posts
     set visibility_status = 'deleted_by_user'
   where id = p_post;
end;
$$;

grant execute on function public.delete_my_post(uuid) to authenticated;
