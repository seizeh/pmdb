-- 행정동 중심좌표 (0021 §6 정밀화). 운영 적용 완료(형상 기록).
-- 1차: 동 이름 지오코딩으로 채움(sync-dong-centroids Edge Function).
-- 추후 행정동 centroid CSV 로 source='csv' upsert 해 교체/보강 가능.
-- 클라이언트 직접 조회 불가(RLS 정책 없음) — posts_by_region(definer)만 읽는다.
create table public.dong_centroids (
  region_code varchar(20) primary key,
  name        text,
  lng         double precision not null,
  lat         double precision not null,
  source      varchar(20) not null default 'geocode', -- geocode | seed | csv
  updated_at  timestamptz not null default now()
);
alter table public.dong_centroids enable row level security;

-- centroid 미보유 행정동의 seed(사용자 좌표 평균) — sync 함수의 지오코딩 대상.
create or replace function public.dong_centroid_seeds()
returns table (region_code varchar, seed_lng double precision, seed_lat double precision)
language sql stable security definer set search_path = '' as $$
  select u.region_code, avg(u.longitude), avg(u.latitude)
    from public.users u
   where u.region_code is not null and u.latitude is not null and u.longitude is not null
     and not exists (select 1 from public.dong_centroids d where d.region_code = u.region_code)
   group by u.region_code
   limit 100;
$$;
grant execute on function public.dong_centroid_seeds() to authenticated, service_role;

-- 클러스터 집계: dong_centroids 있으면 그 좌표, 없으면 사용자 평균(폴백).
create or replace function public.posts_by_region(
  p_min_lng double precision, p_min_lat double precision,
  p_max_lng double precision, p_max_lat double precision
) returns table (
  region_code varchar, post_count bigint,
  lng double precision, lat double precision, post_ids uuid[]
)
language sql stable security definer set search_path = '' as $$
  with uavg as (
    select region_code, avg(longitude) as lng, avg(latitude) as lat
      from public.users
     where region_code is not null and latitude is not null and longitude is not null
     group by region_code
  )
  select p.region_code, count(*)::bigint as post_count,
         coalesce(d.lng, u.lng) as lng, coalesce(d.lat, u.lat) as lat,
         array_agg(p.id order by p.created_at desc) as post_ids
    from public.posts p
    left join public.dong_centroids d on d.region_code = p.region_code
    left join uavg u on u.region_code = p.region_code
   where p.visibility_status = 'visible'
     and coalesce(d.lng, u.lng) is not null
     and coalesce(d.lng, u.lng) between p_min_lng and p_max_lng
     and coalesce(d.lat, u.lat) between p_min_lat and p_max_lat
   group by p.region_code, coalesce(d.lng, u.lng), coalesce(d.lat, u.lat);
$$;
grant execute on function public.posts_by_region(double precision,double precision,double precision,double precision)
  to authenticated;
