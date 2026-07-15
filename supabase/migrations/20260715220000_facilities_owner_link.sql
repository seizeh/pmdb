-- 지도 시설 → 인증 업주 링크 (지도 상세 히어로 탭 → 업체 프로필 이동용).
-- 승인 업체가 매칭된 시설이면 owner_user_id 를 함께 반환한다(업체 얼굴 진입점 —
-- 개인 얼굴 정보는 싣지 않으므로 연결 비노출 원칙과 충돌 없음).
-- 반환 타입 변경이라 DROP 재생성 + GRANT 재부여.

drop function if exists public.facilities_within(double precision, double precision, integer, public.facility_category[]);
create function public.facilities_within(
  p_lng double precision,
  p_lat double precision,
  p_radius_m integer default 5000,
  p_categories public.facility_category[] default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision, source varchar, avg_rating numeric, review_count integer,
  owner_photo_url text, owner_photo_align_y real, owner_user_id uuid
)
language sql stable set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y,
         (select bp.user_id from public.business_profiles bp
           where bp.matched_facility_id = f.id and bp.status = 'approved'
           limit 1) as owner_user_id
    from public.facilities f
   where f.is_open and f.geom is not null
     and (p_categories is null or f.category = any(p_categories))
     and st_dwithin(f.geom, st_makepoint(p_lng, p_lat)::geography,
                    least(coalesce(p_radius_m, 5000), 5000))
   order by distance_m limit 500;
$$;
grant execute on function public.facilities_within(double precision, double precision, integer, public.facility_category[])
  to authenticated, anon;

drop function if exists public.facilities_search(text, double precision, double precision);
create function public.facilities_search(
  p_query text,
  p_lng double precision default null,
  p_lat double precision default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision, source varchar, avg_rating numeric, review_count integer,
  owner_photo_url text, owner_photo_align_y real, owner_user_id uuid
)
language sql stable set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) end as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y,
         (select bp.user_id from public.business_profiles bp
           where bp.matched_facility_id = f.id and bp.status = 'approved'
           limit 1) as owner_user_id
    from public.facilities f
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name limit 30;
$$;
grant execute on function public.facilities_search(text, double precision, double precision)
  to authenticated, anon;
