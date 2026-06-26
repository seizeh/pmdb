-- 게시글 작성 RPC (0018) — 사진 검증 토큰을 트랜잭션 로컬로 안전하게 전달.
--
-- 클라이언트의 posts 직접 INSERT 대신 이 RPC 한 번으로 토큰 전달·INSERT·소진을
-- 한 트랜잭션에서 원자적으로 처리한다. 사진 필수 카테고리는 p_photo_token 필수,
-- free/adoption 은 토큰 없이(null) 호출(트리거가 분기 밖으로 처리).
-- post_pets 연결까지 여기서 수행한다.

create or replace function public.create_post_verified(
  p_category varchar, p_title varchar, p_content text,
  p_scheduled_at timestamptz, p_pet_ids uuid[],
  p_image_url text, p_image_mime varchar, p_image_size int,
  p_photo_token uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := app.uid(); v_post uuid;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

  -- 트리거(app.tg_posts_check_write)가 읽을 토큰을 트랜잭션 로컬로 설정
  perform set_config('app.photo_token', coalesce(p_photo_token::text, ''), true);

  insert into public.posts (
    user_id, category, title, content, scheduled_at,
    image_url, image_mime_type, image_file_size
  ) values (
    v_uid, p_category, p_title, p_content, p_scheduled_at,
    p_image_url, p_image_mime, p_image_size
  ) returning id into v_post;

  if p_pet_ids is not null and array_length(p_pet_ids, 1) >= 1 then
    insert into public.post_pets (post_id, pet_id)
      select v_post, unnest(p_pet_ids);
  end if;

  return v_post;
end;
$$;

grant execute on function public.create_post_verified(
  varchar, varchar, text, timestamptz, uuid[], text, varchar, int, uuid)
  to authenticated;
