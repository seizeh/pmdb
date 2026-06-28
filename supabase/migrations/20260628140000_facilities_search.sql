-- 시설명 검색 RPC (0021) — 지도 검색창용. 이름 ilike, 좌표 있으면 가까운 순.
-- 운영 적용 완료(형상 기록).
create or replace function public.facilities_search(
  p_query text,
  p_lng double precision default null,
  p_lat double precision default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision
)
language sql stable
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography)
         end as distance_m
    from public.facilities f
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name
   limit 30;
$$;
grant execute on function public.facilities_search(text, double precision, double precision)
  to authenticated, anon;
