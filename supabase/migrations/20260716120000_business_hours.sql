-- 업체 영업시간 (자유 서식 한 줄, 예: "매일 10:00 - 20:00 (월 휴무)")
--
-- 저장: business_profiles.business_hours (정본, 승인 업체가 앱에서 수정)
-- 동기화: facilities.business_hours (지도 상세 표시용 — 간판명·전화와 동일 패턴,
--   인허가 월 재적재와 무관한 업주 입력 영역이므로 owner_updated_at 갱신)
-- 노출: facilities_within/search 반환 + public_profiles(승인 업체만) → 업체 프로필.
--
-- ⚠️ update_my_business_info 는 시그니처가 바뀌므로 구버전 drop 필수(오버로드
--    공존 시 PostgREST 가 구버전 호출). facilities_* 는 반환 타입 변경이라 drop 후
--    재생성 — SECURITY DEFINER(20260716090000, 업주 uid RLS 우회) 반드시 유지.

alter table public.business_profiles add column if not exists business_hours varchar(100);
alter table public.facilities add column if not exists business_hours varchar(100);

-- ── 승인 업체 정보 수정 RPC: 영업시간 추가 ──────────────────────────────
-- p_* null = 유지. p_hours 는 빈 문자열이면 삭제(영업시간은 지울 수 있어야 한다).
drop function if exists public.update_my_business_info(text, text, text);

create function public.update_my_business_info(
  p_storefront_name text default null,
  p_phone text default null,
  p_email text default null,
  p_hours text default null
) returns void
language plpgsql security definer set search_path to ''
as $$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_name text := nullif(btrim(coalesce(p_storefront_name, '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_email text := nullif(btrim(coalesce(p_email, '')), '');
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;
  if length(coalesce(p_hours, '')) > 100 then
    raise exception 'hours_too_long' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    storefront_name = coalesce(v_name, storefront_name),
    business_phone  = coalesce(v_phone, business_phone),
    contact_email   = coalesce(v_email, contact_email),
    business_hours  = case when p_hours is null then business_hours
                           else nullif(btrim(p_hours), '') end,
    updated_at = now()
  where user_id = v_me;

  -- 지도 동기화 — 매칭 시설의 간판명·전화·영업시간(주소·업종·영업상태는 인허가 영역)
  if v_row.matched_facility_id is not null
     and (v_name is not null or v_phone is not null or p_hours is not null) then
    update public.facilities set
      name = coalesce(v_name, name),
      phone = coalesce(v_phone, phone),
      business_hours = case when p_hours is null then business_hours
                            else nullif(btrim(p_hours), '') end,
      owner_updated_at = now(),
      updated_at = now()
    where id = v_row.matched_facility_id;
  end if;
end;
$$;

revoke all on function public.update_my_business_info(text, text, text, text) from public;
grant execute on function public.update_my_business_info(text, text, text, text)
  to authenticated, service_role;

-- ── 지도 시설 RPC: business_hours 반환 (반환 타입 변경 → drop 후 재생성) ──
drop function if exists public.facilities_within(double precision, double precision, integer, facility_category[]);

create function public.facilities_within(
  p_lng double precision,
  p_lat double precision,
  p_radius_m integer default 5000,
  p_categories facility_category[] default null
) returns table (
  id uuid, category facility_category, name varchar, address text, phone varchar,
  is_open boolean, lng double precision, lat double precision, distance_m double precision,
  source varchar, avg_rating numeric, review_count integer,
  owner_photo_url text, owner_photo_align_y real, owner_user_id uuid,
  business_hours varchar
) language sql stable security definer set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y,
         (select bp.user_id from public.business_profiles bp
           where bp.matched_facility_id = f.id and bp.status = 'approved'
           limit 1) as owner_user_id,
         f.business_hours
    from public.facilities f
   where f.is_open and f.geom is not null
     and (p_categories is null or f.category = any(p_categories))
     and st_dwithin(f.geom, st_makepoint(p_lng, p_lat)::geography,
                    least(coalesce(p_radius_m, 5000), 5000))
   order by distance_m limit 500;
$$;

drop function if exists public.facilities_search(text, double precision, double precision);

create function public.facilities_search(
  p_query text,
  p_lng double precision default null,
  p_lat double precision default null
) returns table (
  id uuid, category facility_category, name varchar, address text, phone varchar,
  is_open boolean, lng double precision, lat double precision, distance_m double precision,
  source varchar, avg_rating numeric, review_count integer,
  owner_photo_url text, owner_photo_align_y real, owner_user_id uuid,
  business_hours varchar
) language sql stable security definer set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) end as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y,
         (select bp.user_id from public.business_profiles bp
           where bp.matched_facility_id = f.id and bp.status = 'approved'
           limit 1) as owner_user_id,
         f.business_hours
    from public.facilities f
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name limit 30;
$$;

grant execute on function public.facilities_within(double precision, double precision, integer, facility_category[])
  to anon, authenticated, service_role;
grant execute on function public.facilities_search(text, double precision, double precision)
  to anon, authenticated, service_role;

-- ── 공개 프로필 뷰: 승인 업체의 영업시간 노출(컬럼 끝에 추가) ────────────
create or replace view public.public_profiles as
 select u.id,
    u.nickname,
    u.user_type,
    u.profile_image_url,
    u.profile_image_thumbnail_url,
    u.address,
    u.is_location_verified,
    u.created_at,
    u.activity_radius_m,
    coalesce(bp.status::text = 'approved', false) as is_business,
    case when bp.status::text = 'approved' then bp.business_name end as business_name,
    case when bp.status::text = 'approved' then bp.declared_category end as business_category,
    case when bp.status::text = 'approved' then bp.business_address end as business_address,
    case when bp.status::text = 'approved' then bp.business_phone end as business_phone,
    case when bp.status::text = 'approved' then bp.matched_facility_id end as business_facility_id,
    case when bp.status::text = 'approved' then bp.photo_url end as business_photo_url,
    case when bp.status::text = 'approved' then bp.business_hours end as business_hours
   from public.users u
   left join public.business_profiles bp on bp.user_id = u.id;
