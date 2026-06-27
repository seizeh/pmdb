-- 반려동물 시설 지도 (0021) — 공공데이터(병원/미용/위탁/분양) PostGIS 반경조회.
--
-- 좌표는 적재 전에 EPSG:4326(WGS84)로 사전 변환되어 들어온다(X=lng, Y=lat).
-- 데이터(약 24,550건)는 이 마이그레이션이 아니라 별도 적재(대시보드 CSV import →
-- staging → INSERT…SELECT)로 채운다. 본 파일은 스키마/RPC만 정의한다.
-- 운영 PAWMATE 에 적용 완료(형상 기록).

create extension if not exists postgis;

create type public.facility_category as enum (
  'animal_hospital', 'grooming', 'pet_hotel', 'pet_cafe', 'pet_sales'
);

create table public.facilities (
  id            uuid primary key default gen_random_uuid(),
  category      public.facility_category not null,
  source        varchar(30) not null,
  ext_id        varchar(160) not null,
  name          varchar(200) not null,
  address       text,
  phone         varchar(40),
  biz_status    varchar(20),
  is_open       boolean not null default true,
  license_date  date,
  region_code   varchar(20),
  geom          geography(Point, 4326),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint facilities_src_uq unique (source, ext_id)
);

create index facilities_geom_gix on public.facilities using gist (geom);
create index facilities_cat_idx  on public.facilities (category) where is_open;

comment on table public.facilities is
  '공공데이터 반려동물 시설(병원/미용/위탁/분양). geom=WGS84(4326), 적재시 좌표 사전변환 (0021).';

-- 공개 정보 → SELECT 허용, 쓰기는 service_role 만(INSERT/UPDATE/DELETE GRANT 없음).
alter table public.facilities enable row level security;
grant select on public.facilities to authenticated, anon;
create policy facilities_select_all on public.facilities for select using (true);

-- 반경 조회 RPC(public 스키마 — .rpc 노출). 5km 상한 + 500건 제한.
create or replace function public.facilities_within(
  p_lng double precision,
  p_lat double precision,
  p_radius_m integer default 5000,
  p_categories public.facility_category[] default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision
)
language sql stable
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m
    from public.facilities f
   where f.is_open and f.geom is not null
     and (p_categories is null or f.category = any(p_categories))
     and st_dwithin(f.geom, st_makepoint(p_lng, p_lat)::geography,
                    least(coalesce(p_radius_m, 5000), 5000))
   order by distance_m
   limit 500;
$$;
grant execute on function public.facilities_within(double precision, double precision, integer, public.facility_category[])
  to authenticated, anon;
