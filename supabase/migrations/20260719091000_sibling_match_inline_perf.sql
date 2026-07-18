-- 20260719090000 성능 보정 — 형제 판정의 st_dwithin 을 인라인해 gist 인덱스 사용.
--
-- facility_is_sibling() 함수로 감싸니 옵티마이저가 st_dwithin 을 인덱스로 못 풀어
-- 500행 × 전체 스캔(+ilike) 으로 타임아웃. 위치 신호를 '좌표 50m 이내'로 단일화해
-- (전화만 같고 좌표 먼 케이스는 프랜차이즈 오병합 위험이라 포기) st_dwithin 을
-- lateral/join 조건에 직접 두어 s.geom gist 로 후보를 좁힌 뒤 이름/전화를 확인한다.
-- 판정 의미(50m + (이름일치|전화|이름포함))는 동일, 실행만 인덱스 친화적.

drop function if exists public.facility_is_sibling(varchar, text, varchar, geography, varchar, text, varchar, geography);

create or replace function public.facility_sibling_ids(p_id uuid)
returns uuid[]
language sql stable set search_path to 'public'
as $$
  select coalesce(array_agg(s.id), array[p_id])
    from facilities f
    join facilities s
      on s.id = f.id
      or (f.geom is not null and s.geom is not null
          and st_dwithin(s.geom, f.geom, 50)
          and (s.name = f.name
               or (f.phone is not null and s.phone = f.phone)
               or (length(f.name) >= 3 and length(s.name) >= 3
                   and (s.name ilike '%' || f.name || '%'
                        or f.name ilike '%' || s.name || '%'))))
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
   order by f.distance_m nulls last, f.name;
$$;
