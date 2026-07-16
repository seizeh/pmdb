-- 지도 시설 RPC 에 업주 인증(승인) 시각 노출 — 인증 마커끼리 충돌 시
-- 먼저 인증한 업체가 살아남는 우선순위(zIndex) 계산용 (pmdart).
--
-- 반환 타입 변경이라 drop 후 재생성. SECURITY DEFINER(20260716090000,
-- 업주 정보 RLS 우회) 반드시 유지. 업주 서브쿼리 2회 → lateral 1회로 정리.

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
  business_hours varchar, owner_verified_at timestamptz
) language sql stable security definer set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y,
         ob.user_id as owner_user_id,
         f.business_hours,
         ob.reviewed_at as owner_verified_at
    from public.facilities f
    left join lateral (
      select bp.user_id, bp.reviewed_at from public.business_profiles bp
       where bp.matched_facility_id = f.id and bp.status = 'approved'
       limit 1
    ) ob on true
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
  business_hours varchar, owner_verified_at timestamptz
) language sql stable security definer set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) end as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y,
         ob.user_id as owner_user_id,
         f.business_hours,
         ob.reviewed_at as owner_verified_at
    from public.facilities f
    left join lateral (
      select bp.user_id, bp.reviewed_at from public.business_profiles bp
       where bp.matched_facility_id = f.id and bp.status = 'approved'
       limit 1
    ) ob on true
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name limit 30;
$$;

grant execute on function public.facilities_within(double precision, double precision, integer, facility_category[])
  to anon, authenticated, service_role;
grant execute on function public.facilities_search(text, double precision, double precision)
  to anon, authenticated, service_role;
