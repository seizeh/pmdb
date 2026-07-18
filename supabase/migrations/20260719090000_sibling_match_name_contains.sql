-- 같은 업체(형제 행) 판정 3차 보강 — 이름이 다른 다중 카테고리 업체(댕댕즈 사례)
--
-- 뉴엘(20260718090000)은 '이름 같고 주소만 마스킹 달라' 50m/전화로 해결했지만,
-- 댕댕즈는 정반대다: 좌표는 같은데(0m) 이름이 다르다 —
-- 미용 '댕댕즈' vs 분양 '동탄강아지분양 고양이분양 댕댕즈'. 이름 정확일치를
-- 필수로 두면 놓친다(실사용 확인: 같은 업장).
--
-- 새 판정: (좌표 50m 이내 OR 전화 일치) AND (이름 일치 OR 전화 일치 OR
--          이름 상호포함 3자 이상). 위치 신호로 후보를 좁힌 뒤 이름 신호로
--          확정 — 프랜차이즈 동명 타지점은 좌표·전화가 달라 병합 안 됨,
--          같은 자리의 무관 업체는 이름이 겹치지 않아 병합 안 됨.
--          주소 문자열 일치는 마스킹 남발 위험이 있어 위치 신호에서 제외
--          (좌표/전화가 실질 신호). 성능: st_dwithin(gist)로 좁혀 이름
--          ilike 는 소수 후보에만.
--
-- 적용: facility_sibling_ids(후기 통합·차단·삭제·정보 동기화·카테고리 칩의
--       정본) + facilities_within/search 의 형제/업주 lateral.

-- 두 시설이 같은 업체인지 — 판정을 한 곳에 모아 재사용(가독·일관).
create or replace function public.facility_is_sibling(
  a_name varchar, a_addr text, a_phone varchar, a_geom geography,
  b_name varchar, b_addr text, b_phone varchar, b_geom geography
) returns boolean
language sql immutable
as $$
  select
    -- 위치 신호
    ((a_geom is not null and b_geom is not null and st_dwithin(a_geom, b_geom, 50))
     or (a_phone is not null and a_phone = b_phone))
    and
    -- 이름 신호
    (a_name = b_name
     or (a_phone is not null and a_phone = b_phone)
     or (length(a_name) >= 3 and length(b_name) >= 3
         and (b_name ilike '%' || a_name || '%'
              or a_name ilike '%' || b_name || '%')));
$$;

create or replace function public.facility_sibling_ids(p_id uuid)
returns uuid[]
language sql stable set search_path to 'public'
as $$
  select coalesce(array_agg(s.id), array[p_id])
    from facilities f
    join facilities s
      on s.id = f.id
      or public.facility_is_sibling(f.name, f.address, f.phone, f.geom,
                                    s.name, s.address, s.phone, s.geom)
   where f.id = p_id;
$$;

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
    left join lateral (
      select array_agg(s.id) as ids,
             sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or public.facility_is_sibling(f.name, f.address, f.phone, f.geom,
                                        s.name, s.address, s.phone, s.geom)
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
          or public.facility_is_sibling(f.name, f.address, f.phone, f.geom,
                                        s.name, s.address, s.phone, s.geom)
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
