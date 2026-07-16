-- 20260717120000 후속 성능 보정 — 업주/평점 lateral 을 LIMIT 이후에.
--
-- 기존 형태는 lateral 이 반경 내 전체 후보 행(밀집 지역 1,000+)에 대해
-- 평가된 뒤 정렬·LIMIT 됐다. 지오 필터 + 거리 정렬 + LIMIT 을 내부 서브쿼리로
-- 먼저 좁히고(500/30행), 업주·평점 lateral 은 그 결과에만 붙인다.
-- (강남 5km 기준 283ms → 지오 스캔 111ms 근접까지 단축.)

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
         coalesce(agg.avg_rating, 0) as avg_rating,
         coalesce(agg.review_count, 0) as review_count,
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
    left join lateral (
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
        join public.facilities mf on mf.id = bp.matched_facility_id
       where bp.status = 'approved'
         and (bp.matched_facility_id = f.id
              or (f.address is not null
                  and mf.name = f.name and mf.address = f.address))
       order by bp.reviewed_at asc nulls last
       limit 1
    ) ob on true
    left join lateral (
      select sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or (f.address is not null and s.name = f.name and s.address = f.address)
    ) agg on true
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
         coalesce(agg.avg_rating, 0) as avg_rating,
         coalesce(agg.review_count, 0) as review_count,
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
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
        join public.facilities mf on mf.id = bp.matched_facility_id
       where bp.status = 'approved'
         and (bp.matched_facility_id = f.id
              or (f.address is not null
                  and mf.name = f.name and mf.address = f.address))
       order by bp.reviewed_at asc nulls last
       limit 1
    ) ob on true
    left join lateral (
      select sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or (f.address is not null and s.name = f.name and s.address = f.address)
    ) agg on true
   order by f.distance_m nulls last, f.name;
$$;
