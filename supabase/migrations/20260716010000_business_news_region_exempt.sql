-- 업체 소식(news)은 동네 인증 없이 작성 가능 — 지역은 사업장 주소 기준.
--
-- 1) tg_posts_set_region: 업체 모드 글은 개인 동네 인증 게이트를 건너뛰고
--    승인 업체(business_profiles)의 business_region_code / 사업장 주소 동을
--    region_code / display_address 로 스탬프. 미승인 업체 모드 글은 거부.
--    (트리거 순서: trg_posts_authored_as 가 먼저 실행돼 authored_as 확정됨)
-- 2) create_post_verified(12-param, 유일 오버로드): 같은 게이트를 업체 모드에
--    한해 생략(강제는 어차피 트리거가 담당).
-- 3) 회귀 복원: 20260713202500 게이트 리라이트가 0021 의 작성자 동
--    display_address 스탬프를 누락시킴 — 로직 복원 + 누락분 백필.

create or replace function app.tg_posts_set_region()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_user record;
  v_biz  record;
  v_parts text[];
  v_dong text;
begin
  -- 업체 모드 글(소식): 개인 동네 인증 불필요 — 지역/표시 동은 승인 사업장 기준.
  if new.authored_as = 'business' then
    select business_region_code,
           coalesce(business_address_jibun, business_address) as addr
      into v_biz
      from public.business_profiles
     where user_id = new.user_id and status = 'approved';
    if not found then
      raise exception 'posts: 승인된 업체만 소식을 작성할 수 있어요';
    end if;
    if new.region_code is null then
      new.region_code := v_biz.business_region_code;
    end if;
    if new.display_address is null and v_biz.addr is not null then
      -- 주소에서 동/읍/면/가/리 토큰 추출(지번주소 우선이라 대부분 존재).
      select t into v_dong
        from unnest(regexp_split_to_array(btrim(v_biz.addr), '\s+'))
             with ordinality as u(t, ord)
       where t ~ '(동|읍|면|가|리)$'
       order by ord limit 1;
      new.display_address := v_dong;
    end if;
    return new;
  end if;

  select region_code, address, is_location_verified, last_verified_at
    into v_user
    from public.users where id = new.user_id;

  if not app.is_admin() then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if new.region_code is null then
    new.region_code := v_user.region_code;
  end if;

  -- 작성자 동(마지막 토큰) 표시 스탬프 — 0021 로직 복원(0713 리라이트 누락분).
  if new.display_address is null and v_user.address is not null
     and length(btrim(v_user.address)) > 0 then
    v_parts := regexp_split_to_array(btrim(v_user.address), '\s+');
    new.display_address := v_parts[cardinality(v_parts)];
  end if;
  return new;
end $$;

-- 0713 이후 동 스탬프가 누락된 개인 글 백필.
update public.posts p
   set display_address = (regexp_split_to_array(btrim(u.address), '\s+'))[
         cardinality(regexp_split_to_array(btrim(u.address), '\s+'))]
  from public.users u
 where u.id = p.user_id
   and p.display_address is null
   and p.authored_as = 'personal'
   and u.address is not null and length(btrim(u.address)) > 0;

-- RPC 게이트: 업체 모드는 생략(그 외 로직은 20260713201500 과 동일).
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
  -- 개인 모드는 미인증/만료(30일) 시 카테고리 무관 작성 불가.
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
