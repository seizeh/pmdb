-- 업체 대표 사진 → 지도 상세 히어로 (0025 후속 — 업체 프로필 분리 3차).
-- 승인 업체가 대표 사진을 설정하면 지도 시설 상세가 커뮤니티 게시글처럼
-- 큰 사진 + 하단 블러 위 정보 레이아웃으로 표시된다. 사진의 세로 초점(align_y,
-- -1=상단 ~ 1=하단)을 업주가 조절해 상세 화면에서 보일 영역을 정한다.
--
-- 원본은 business_profiles(photo_*), 지도 노출용 사본은 facilities(owner_photo_*) —
-- 시설 조회가 공개 경로(facilities RPC)라 별도 조인 없이 그대로 흐른다.
-- owner_photo_* 는 소유자 전용 컬럼이라 월 재적재(upsert)와 충돌하지 않는다.

alter table public.facilities
  add column if not exists owner_photo_url text,
  add column if not exists owner_photo_align_y real not null default 0;

alter table public.business_profiles
  add column if not exists photo_url text,
  add column if not exists photo_align_y real not null default 0;

-- 시설 조회 RPC 2종 — 반환 컬럼 추가는 반환 타입 변경이라 DROP 후 재생성(+GRANT 재부여).
drop function if exists public.facilities_within(double precision, double precision, integer, public.facility_category[]);
create function public.facilities_within(
  p_lng double precision,
  p_lat double precision,
  p_radius_m integer default 5000,
  p_categories public.facility_category[] default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision, source varchar, avg_rating numeric, review_count integer,
  owner_photo_url text, owner_photo_align_y real
)
language sql stable set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y
    from public.facilities f
   where f.is_open and f.geom is not null
     and (p_categories is null or f.category = any(p_categories))
     and st_dwithin(f.geom, st_makepoint(p_lng, p_lat)::geography,
                    least(coalesce(p_radius_m, 5000), 5000))
   order by distance_m limit 500;
$$;
grant execute on function public.facilities_within(double precision, double precision, integer, public.facility_category[])
  to authenticated, anon;

drop function if exists public.facilities_search(text, double precision, double precision);
create function public.facilities_search(
  p_query text,
  p_lng double precision default null,
  p_lat double precision default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision, source varchar, avg_rating numeric, review_count integer,
  owner_photo_url text, owner_photo_align_y real
)
language sql stable set search_path to 'public'
as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) end as distance_m,
         f.source, f.avg_rating, f.review_count,
         f.owner_photo_url, f.owner_photo_align_y
    from public.facilities f
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name limit 30;
$$;
grant execute on function public.facilities_search(text, double precision, double precision)
  to authenticated, anon;

-- 대표 사진 설정/해제 — 승인 업체 본인만. p_url null 이면 사진 제거.
create or replace function public.set_my_business_photo(
  p_url     text default null,
  p_align_y real default 0
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_align real := greatest(-1, least(1, coalesce(p_align_y, 0)));
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    photo_url = p_url, photo_align_y = v_align, updated_at = now()
  where user_id = v_me;

  if v_row.matched_facility_id is not null then
    update public.facilities set
      owner_photo_url = p_url, owner_photo_align_y = v_align,
      owner_updated_at = now(), updated_at = now()
    where id = v_row.matched_facility_id;
  end if;
end;
$function$;

revoke all on function public.set_my_business_photo(text, real) from public, anon;
grant execute on function public.set_my_business_photo(text, real) to authenticated;
