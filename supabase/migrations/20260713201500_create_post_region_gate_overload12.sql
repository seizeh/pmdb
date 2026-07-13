-- create_post_verified 12-파라미터 오버로드에도 동네 인증 게이트 적용.
--
-- 20260703120000(pet_trust_score) 이 기존 9-파라미터를 drop 하지 않고
-- 12-파라미터(신뢰 펫 검증 생략 + 위치 파라미터) 오버로드를 추가해 둘이 공존한다.
-- 앱(PostgREST named args 9개)은 9-파라미터를 호출하지만, 12-파라미터도
-- authenticated EXECUTE 가 있어 직접 호출하면 지역 인증 게이트를 우회할 수
-- 있으므로 같은 게이트를 넣는다(그 외 로직은 20260703120000 과 동일).

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

  -- 동네 인증 게이트 — 미인증/만료(30일) 사용자는 카테고리 무관 작성 불가.
  -- 30일은 verify-post-photo REVERIFY_DAYS(30)·위치기반서비스 약관과 동일 유지.
  select region_code, is_location_verified, last_verified_at
    into v_user
    from public.users where id = v_uid;
  if v_user.region_code is null
     or not coalesce(v_user.is_location_verified, false)
     or v_user.last_verified_at is null
     or v_user.last_verified_at < now() - interval '30 days' then
    raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
  end if;

  if p_category in ('walk_together','walk_proxy','care','give_away') then
    v_all_trusted := p_pet_ids is not null
                 and array_length(p_pet_ids, 1) >= 1
                 and not exists (
                       select 1 from public.pets
                        where id = any(p_pet_ids) and trust_score < 3);

    if v_all_trusted then
      -- 모든 연결 펫이 신뢰 → 사진 검증 생략(트리거 우회 플래그).
      perform set_config('app.photo_trusted', 'true', true);
    else
      -- 미인증 펫 포함 → 사진 검증 필수. 촬영 대상은 미인증 펫이어야 한다.
      select * into v_pv from public.photo_verifications where id = p_photo_token;
      if not found or v_pv.pet_id is null then
        raise exception 'posts: 사진 검증 정보가 올바르지 않습니다';
      end if;
      if p_pet_ids is null or not (v_pv.pet_id = any(p_pet_ids)) then
        raise exception 'posts: 촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다';
      end if;
      if (select trust_score from public.pets where id = v_pv.pet_id) >= 3 then
        raise exception 'posts: 인증이 필요한 반려동물을 촬영해주세요';
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
