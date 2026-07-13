-- create_post_verified v3 — 동네(지역) 인증 게이트 추가.
--
-- 문제: 사진 검증이 없는 카테고리(adoption, free)는 create_post_verified 가
-- 지역 인증을 확인하지 않아 미인증 사용자도 게시글을 작성할 수 있었다.
-- (검증 카테고리는 verify-post-photo 가 not_verified 로 이미 차단.)
--
-- 수정: 모든 카테고리에서 작성 전에 다음을 요구한다.
--   is_location_verified = true AND region_code IS NOT NULL
--   AND last_verified_at 이 30일 이내
-- 30일은 verify-post-photo 의 REVERIFY_DAYS(30)·위치기반서비스 이용약관과
-- 동일하게 유지할 것(변경 시 세 곳 동시 수정).

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
declare
  v_uid  uuid := app.uid();
  v_post uuid;
  v_pv   public.photo_verifications%rowtype;
  v_user record;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

  -- [v3] 동네 인증 게이트 — 미인증/만료(30일) 사용자는 카테고리 무관 작성 불가.
  select region_code, is_location_verified, last_verified_at
    into v_user
    from public.users where id = v_uid;
  if v_user.region_code is null
     or not coalesce(v_user.is_location_verified, false)
     or v_user.last_verified_at is null
     or v_user.last_verified_at < now() - interval '30 days' then
    raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
  end if;

  -- 검증 카테고리는 토큰의 펫이 실제 연결할 펫에 포함돼야 한다(우회 차단).
  if p_category in ('walk_together','walk_proxy','care','give_away') then
    select * into v_pv from public.photo_verifications where id = p_photo_token;
    if not found or v_pv.pet_id is null then
      raise exception 'posts: 사진 검증 정보가 올바르지 않습니다';
    end if;
    if p_pet_ids is null or not (v_pv.pet_id = any(p_pet_ids)) then
      raise exception 'posts: 촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다';
    end if;
  end if;

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

  -- [0019] 개체 일치 성공 → 펫 신뢰도 가산(검증 카테고리에서만 토큰이 존재).
  if v_pv.id is not null and v_pv.ai_matched then
    update public.pets set pet_match_count = pet_match_count + 1
     where id = v_pv.pet_id;
  end if;

  return v_post;
end;
$$;
