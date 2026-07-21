-- 게시글 사진 인증: 촬영 대상을 '연결한 펫 중 아무나'로 완화.
--
-- 기존에는 미인증(trust<3) 펫이 섞이면 사진 검증이 필수인 것에 더해
-- '촬영 대상도 미인증 펫이어야' 했다(trust>=3 펫 토큰이면 거부). 그래서
-- 인증된 펫 + 미인증 펫을 함께 연결하면 인증된 펫은 촬영할 수 없었다.
--
-- 정책 변경(앱 post_create_screen 과 동시 적용):
--   · 사진 검증 필요 조건은 그대로(미인증 펫 포함 시 필수, 전부 신뢰면 생략).
--   · 촬영 대상은 연결한 펫 중 아무나 — 한 마리만 동일개체 대조를 통과하면
--     게시글을 등록할 수 있다. (여러 마리 연결 시 앱이 사진 속 펫을 물어봄)
--
-- 이 정의는 2026-07-20 프로덕션 현재 정의(업체 모드 게이트 포함) 기준이며,
-- 변경점은 '인증이 필요한 반려동물을 촬영해주세요' 거부 블록 제거뿐이다.

create or replace function public.create_post_verified(
  p_category character varying, p_title character varying, p_content text,
  p_scheduled_at timestamp with time zone, p_pet_ids uuid[],
  p_image_url text, p_image_mime character varying, p_image_size integer,
  p_photo_token uuid default null,
  p_actual_lat double precision default null,
  p_actual_lng double precision default null,
  p_region_code character varying default null
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid  uuid := app.uid();
  v_post uuid;
  v_pv   public.photo_verifications%rowtype;
  v_all_trusted boolean := false;
  v_user record;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

  -- 동네 인증 게이트 — 업체 모드(소식 전용)는 사업장 주소 기준이라 생략
  -- (승인 여부·지역 스탬프는 tg_posts_set_region 트리거가 강제).
  select region_code, is_location_verified, last_verified_at, active_mode
    into v_user
    from public.users where id = v_uid;
  if v_user.active_mode is distinct from 'business' then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if p_category in ('walk_together','walk_proxy','care','give_away') then
    v_all_trusted := p_pet_ids is not null
                 and array_length(p_pet_ids, 1) >= 1
                 and not exists (
                       select 1 from public.pets
                        where id = any(p_pet_ids) and trust_score < 3);

    if v_all_trusted then
      perform set_config('app.photo_trusted', 'true', true);
    else
      -- 미인증 펫 포함 → 사진 검증 필수. 촬영 대상은 연결 펫 중 아무나
      -- (한 마리 통과로 충분 — 인증된 펫을 촬영해도 된다).
      select * into v_pv from public.photo_verifications where id = p_photo_token;
      if not found or v_pv.pet_id is null then
        raise exception 'posts: 사진 검증 정보가 올바르지 않습니다';
      end if;
      if p_pet_ids is null or not (v_pv.pet_id = any(p_pet_ids)) then
        raise exception 'posts: 촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다';
      end if;
    end if;
  end if;

  perform set_config('app.photo_token', coalesce(p_photo_token::text, ''), true);

  insert into public.posts (
    user_id, category, title, content, scheduled_at,
    image_url, image_mime_type, image_file_size,
    actual_lat, actual_lng, region_code
  ) values (
    v_uid, p_category, p_title, p_content, p_scheduled_at,
    p_image_url, p_image_mime, p_image_size,
    p_actual_lat, p_actual_lng, p_region_code
  ) returning id into v_post;

  if p_pet_ids is not null and array_length(p_pet_ids, 1) >= 1 then
    insert into public.post_pets (post_id, pet_id)
      select v_post, unnest(p_pet_ids);
  end if;

  if v_pv.id is not null and v_pv.ai_matched then
    update public.pets set pet_match_count = pet_match_count + 1
     where id = v_pv.pet_id;
  end if;

  return v_post;
end;
$function$;
