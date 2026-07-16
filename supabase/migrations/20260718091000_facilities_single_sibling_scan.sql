-- 20260718090000 후속 성능 보정 — 형제 스캔을 행당 한 번으로.
--
-- 판정 보강(주소 or 전화 or 50m)으로 업주·평점 lateral 이 각각 형제 집합을
-- 스캔하면서 강남 5km 500행 기준 202→482ms 로 늘었다. 형제 id 목록과 평점
-- 집계를 한 lateral 로 합치고, 업주는 그 id 목록으로 소형 테이블
-- (business_profiles)에서 찾는다 → 131ms (통합 이전 202ms 보다 빠름).

create or replace function public.facilities_within(
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
         f.distance_m, f.source,
         coalesce(sib.avg_rating, 0) as avg_rating,
         coalesce(sib.review_count, 0) as review_count,
         ob.photo_url as owner_photo_url,
         coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
         ob.user_id as owner_user_id,
         ob.business_hours,
         ob.reviewed_at as owner_verified_at
    from (
      select f0.*,
             st_distance(f0.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m
        from public.facilities f0
       where f0.is_open and f0.geom is not null
         and (p_categories is null or f0.category = any(p_categories))
         and st_dwithin(f0.geom, st_makepoint(p_lng, p_lat)::geography,
                        least(coalesce(p_radius_m, 5000), 5000))
       order by distance_m limit 500
    ) f
    -- 형제(같은 업체) 스캔은 행당 한 번 — id 목록과 평점 집계를 함께.
    left join lateral (
      select array_agg(s.id) as ids,
             sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or (s.name = f.name and (
                (f.address is not null and s.address = f.address)
             or (f.phone is not null and s.phone = f.phone)
             or (s.geom is not null and st_dwithin(s.geom, f.geom, 50))
          ))
    ) sib on true
    -- 업주는 형제 id 목록으로 소형 테이블(business_profiles)에서 조회.
    left join lateral (
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
       where bp.status = 'approved'
         and bp.matched_facility_id = any(sib.ids)
       order by bp.reviewed_at asc nulls last
       limit 1
    ) ob on true
   order by f.distance_m;
$$;

create or replace function public.facilities_search(
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
         f.distance_m, f.source,
         coalesce(sib.avg_rating, 0) as avg_rating,
         coalesce(sib.review_count, 0) as review_count,
         ob.photo_url as owner_photo_url,
         coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
         ob.user_id as owner_user_id,
         ob.business_hours,
         ob.reviewed_at as owner_verified_at
    from (
      select f0.*,
             case when p_lng is not null and p_lat is not null
                  then st_distance(f0.geom, st_makepoint(p_lng, p_lat)::geography)
             end as distance_m
        from public.facilities f0
       where f0.is_open and f0.geom is not null
         and f0.name ilike '%' || p_query || '%'
       order by distance_m nulls last, f0.name limit 30
    ) f
    left join lateral (
      select array_agg(s.id) as ids,
             sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or (s.name = f.name and (
                (f.address is not null and s.address = f.address)
             or (f.phone is not null and s.phone = f.phone)
             or (s.geom is not null and f.geom is not null
                 and st_dwithin(s.geom, f.geom, 50))
          ))
    ) sib on true
    left join lateral (
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
       where bp.status = 'approved'
         and bp.matched_facility_id = any(sib.ids)
       order by bp.reviewed_at asc nulls last
       limit 1
    ) ob on true
   order by f.distance_m nulls last, f.name;
$$;
