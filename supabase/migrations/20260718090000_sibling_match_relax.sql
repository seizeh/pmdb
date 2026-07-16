-- 같은 업체(형제 행) 판정 보강 — 주소 정확 일치의 실데이터 함정 수정
--
-- LOCALDATA 는 일부 행의 주소를 마스킹한다(예: 뉴엘동물의료센터 미용 행
-- "동탄대로시범길 ***, 리더스프라자 *층") — 병원 행과 이름·전화가 같아도
-- 주소 문자열이 달라 20260717120000 의 '이름+주소 정확 일치' 기준이 깨져
-- 후기·인증이 통합되지 않았다(이름 같고 주소 다른 실제 형제: 전화 일치
-- 739쌍, 50m 이내 1,837쌍).
--
-- 새 기준: 이름 일치 AND (주소 일치 OR 전화 일치 OR 좌표 50m 이내).
-- 프랜차이즈 동명 타지점은 전화·좌표가 다르므로 병합되지 않는다.
-- 적용 대상: facility_sibling_ids(후기 통합·차단·삭제·정보 동기화의 정본),
-- facilities_within/search 의 업주·평점 lateral, facility_all_categories(칩).

create or replace function public.facility_sibling_ids(p_id uuid)
returns uuid[]
language sql stable set search_path to 'public'
as $$
  select coalesce(array_agg(s.id), array[p_id])
    from facilities f
    join facilities s
      on s.id = f.id
      or (s.name = f.name and (
            (f.address is not null and s.address = f.address)
         or (f.phone is not null and s.phone = f.phone)
         or (f.geom is not null and s.geom is not null
             and st_dwithin(s.geom, f.geom, 50))
      ))
   where f.id = p_id;
$$;

create or replace function public.facility_all_categories(p_id uuid)
returns text[]
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(array_agg(distinct s.category::text order by s.category::text),
                  array[]::text[])
    from facilities s
   where s.id = any(public.facility_sibling_ids(p_id));
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
              or (mf.name = f.name and (
                    (f.address is not null and mf.address = f.address)
                 or (f.phone is not null and mf.phone = f.phone)
                 or (mf.geom is not null and st_dwithin(mf.geom, f.geom, 50))
              )))
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
          or (s.name = f.name and (
                (f.address is not null and s.address = f.address)
             or (f.phone is not null and s.phone = f.phone)
             or (s.geom is not null and st_dwithin(s.geom, f.geom, 50))
          ))
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
              or (mf.name = f.name and (
                    (f.address is not null and mf.address = f.address)
                 or (f.phone is not null and mf.phone = f.phone)
                 or (mf.geom is not null and f.geom is not null
                     and st_dwithin(mf.geom, f.geom, 50))
              )))
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
          or (s.name = f.name and (
                (f.address is not null and s.address = f.address)
             or (f.phone is not null and s.phone = f.phone)
             or (s.geom is not null and f.geom is not null
                 and st_dwithin(s.geom, f.geom, 50))
          ))
    ) agg on true
   order by f.distance_m nulls last, f.name;
$$;
