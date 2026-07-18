-- 검색 dedupe 대표 행에 형제 전체 카테고리 배열(categories) 노출
--
-- 검색은 형제 그룹당 1행(대표)만 반환하는데(20260719120000) 대표의 category 는
-- 하나뿐이라, 클라이언트 자동완성의 카테고리 칩 필터(f.category == 선택)에서
-- 다른 카테고리 선택 시 사라진다(댕댕즈: 대표=분양이라 미용 칩에서 누락).
-- 대표에 형제 전체 카테고리 배열을 실어 클라이언트가 '포함' 여부로 필터하게 한다.
--
-- 반환 컬럼 추가(categories text[]) — drop 후 재생성. SECURITY DEFINER 유지.

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
  business_hours varchar, owner_verified_at timestamptz, categories text[]
) language sql stable security definer set search_path to 'public'
as $$
  select r.id, r.category, r.name, r.address, r.phone, r.is_open,
         r.lng, r.lat, r.distance_m, r.source,
         r.avg_rating, r.review_count,
         r.owner_photo_url, r.owner_photo_align_y, r.owner_user_id,
         r.business_hours, r.owner_verified_at, r.categories
    from (
      select distinct on (sib.canonical)
             f.id, f.category, f.name, f.address, f.phone, f.is_open,
             st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
             f.distance_m, f.source,
             coalesce(sib.avg_rating, 0) as avg_rating,
             coalesce(sib.review_count, 0) as review_count,
             ob.photo_url as owner_photo_url,
             coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
             ob.user_id as owner_user_id,
             ob.business_hours,
             ob.reviewed_at as owner_verified_at,
             sib.categories
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
                 min(s.id::text) as canonical,
                 array_agg(distinct s.category::text) as categories,
                 sum(s.review_count)::int as review_count,
                 case when sum(s.review_count) > 0
                      then round(sum(s.avg_rating * s.review_count)::numeric
                                 / sum(s.review_count), 1)
                 end as avg_rating
            from public.facilities s
           where s.id = f.id
              or (s.geom is not null and st_dwithin(s.geom, f.geom, 50)
                  and (s.name = f.name
                       or (f.phone is not null and s.phone = f.phone)
                       or (length(f.name) >= 3 and length(s.name) >= 3
                           and (s.name ilike '%' || f.name || '%'
                                or f.name ilike '%' || s.name || '%'))))
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
        order by sib.canonical,
                 (ob.user_id is not null) desc,
                 f.distance_m nulls last, f.id
    ) r
   order by r.distance_m nulls last, r.name;
$$;

grant execute on function public.facilities_search(text, double precision, double precision)
  to anon, authenticated, service_role;
