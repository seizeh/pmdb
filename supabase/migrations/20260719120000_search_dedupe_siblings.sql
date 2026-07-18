-- 시설 검색 결과에서 같은 업장(형제 행) 중복 제거
--
-- 다중 카테고리 업체(댕댕즈: 미용+분양)는 카테고리별 별도 행이라 검색에
-- 같은 업장이 2개 이상 나온다. 형제 그룹당 1행만 — 대표는 인증 업체 행
-- 우선(간판명이 동기화된 정본), 없으면 가까운/작은 id. 평점·후기 수는
-- 형제 통합 집계(기존과 동일). distinct on (형제 canonical=min(형제 id)).
--
-- 참고: 업체가 정보 수정으로 간판명을 바꾸면 update_my_business_info 가
-- 형제 행 전체의 facilities.name 을 함께 갱신하므로(20260718150000),
-- 바뀐 이름으로 검색해도 name ilike 로 매칭되고 형제 관계는 좌표(50m)로
-- 유지된다 — 조회에 문제없다.

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
  -- 형제 그룹당 대표 1행만 골라(distinct on) 다시 거리순 정렬.
  select r.id, r.category, r.name, r.address, r.phone, r.is_open,
         r.lng, r.lat, r.distance_m, r.source,
         r.avg_rating, r.review_count,
         r.owner_photo_url, r.owner_photo_align_y, r.owner_user_id,
         r.business_hours, r.owner_verified_at
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
                 min(s.id::text) as canonical,
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
        -- 대표 선정: 인증 업체 행 우선 → 가까운 거리 → 작은 id.
        order by sib.canonical,
                 (ob.user_id is not null) desc,
                 f.distance_m nulls last, f.id
    ) r
   order by r.distance_m nulls last, r.name;
$$;
