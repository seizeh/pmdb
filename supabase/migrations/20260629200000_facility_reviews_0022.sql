-- 0022 시설 후기 정비 — 카페 승격 + 평균 캐시 + RPC 전용 쓰기. 운영 적용 완료(형상 기록).
-- 기반: 20260629180000_facility_reviews.sql (PR#18). 여기선 0022 정합으로 증분.

-- (1) facilities 집계 컬럼
alter table public.facilities
  add column if not exists avg_rating   numeric(2,1) not null default 0,
  add column if not exists review_count integer      not null default 0;

-- (2) facility_reviews 보강 + 쓰기 RPC 전용화
alter table public.facility_reviews
  add column if not exists photo_paths text[] not null default '{}',
  add column if not exists visibility_status varchar(20) not null default 'visible';
alter table public.facility_reviews drop constraint if exists facility_reviews_photos_max;
alter table public.facility_reviews add constraint facility_reviews_photos_max
  check (array_length(photo_paths,1) is null or array_length(photo_paths,1) <= 5);

revoke insert, update, delete on public.facility_reviews from authenticated;
drop policy if exists fr_select on public.facility_reviews;
drop policy if exists fr_insert on public.facility_reviews;
drop policy if exists fr_update on public.facility_reviews;
drop policy if exists fr_delete on public.facility_reviews;
create policy fr_select on public.facility_reviews
  for select using (visibility_status = 'visible' or user_id = app.uid());

drop view if exists public.v_facility_reviews;

-- (3) 카페 승격(없으면 생성) — 이름+주소 해시 키
create or replace function public.ensure_naver_facility(
  p_name text, p_address text, p_phone text,
  p_lng double precision, p_lat double precision
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_ext text; v_id uuid;
begin
  if app.uid() is null then raise exception 'auth required'; end if;
  v_ext := md5(lower(regexp_replace(coalesce(p_name,'')||'|'||coalesce(p_address,''), '\s', '', 'g')));
  insert into public.facilities (category, source, ext_id, name, address, phone, is_open, geom)
  values ('pet_cafe', 'naver', v_ext, p_name, p_address, p_phone, true,
          public.st_setsrid(public.st_makepoint(p_lng, p_lat), 4326)::public.geography)
  on conflict (source, ext_id) do update set name = excluded.name
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.ensure_naver_facility(text,text,text,double precision,double precision) to authenticated;

-- 승격된 카페 facility_id 해석(없으면 null, 생성 안 함) — 조회용
create or replace function public.naver_facility_id(p_name text, p_address text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.facilities
   where source = 'naver'
     and ext_id = md5(lower(regexp_replace(coalesce(p_name,'')||'|'||coalesce(p_address,''), '\s', '', 'g')))
   limit 1;
$$;
grant execute on function public.naver_facility_id(text,text) to authenticated, anon;

-- (4) 집계 트리거(app 스키마 내부용)
create or replace function app.refresh_facility_aggs(p_facility uuid)
returns void language sql security definer set search_path = '' as $$
  update public.facilities f set
    review_count = sub.cnt,
    avg_rating   = coalesce(round(sub.avg_r, 1), 0)
  from (select count(*) cnt, avg(rating)::numeric avg_r
          from public.facility_reviews
         where facility_id = p_facility and visibility_status = 'visible') sub
  where f.id = p_facility;
$$;
create or replace function app.tg_facility_review_aggs()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app.refresh_facility_aggs(coalesce(new.facility_id, old.facility_id));
  return null;
end $$;
drop trigger if exists facility_reviews_aggs on public.facility_reviews;
create trigger facility_reviews_aggs after insert or update or delete
  on public.facility_reviews for each row execute function app.tg_facility_review_aggs();

-- (5) 작성/삭제/목록 RPC (review_id 서버 생성)
create or replace function public.add_facility_review(
  p_facility uuid, p_rating smallint, p_body text,
  p_paths text[] default '{}', p_urls text[] default '{}'
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := app.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls)
  values (p_facility, v_uid, p_rating, p_body, coalesce(p_paths,'{}'), coalesce(p_urls,'{}'))
  on conflict (facility_id, user_id) do update
    set rating = excluded.rating, content = excluded.content,
        photo_paths = excluded.photo_paths, photo_urls = excluded.photo_urls,
        visibility_status = 'visible', updated_at = now()
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.add_facility_review(uuid,smallint,text,text[],text[]) to authenticated;

create or replace function public.delete_facility_review(p_facility uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := app.uid();
begin
  if v_uid is null then raise exception 'auth required'; end if;
  update public.facility_reviews set visibility_status = 'deleted_by_user', updated_at = now()
   where facility_id = p_facility and user_id = v_uid;
end $$;
grant execute on function public.delete_facility_review(uuid) to authenticated;

create or replace function public.facility_reviews_of(
  p_facility uuid, p_limit int default 20, p_offset int default 0
) returns table (
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean
) language sql stable security definer set search_path = '' as $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid())
    from public.facility_reviews r
    left join public.public_profiles pr on pr.id = r.user_id
   where r.facility_id = p_facility and r.visibility_status = 'visible'
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$$;
grant execute on function public.facility_reviews_of(uuid,int,int) to authenticated, anon;

-- (6) facilities_within / facilities_search 에 source/avg/count 추가(반환형 변경 → 재생성)
drop function if exists public.facilities_within(double precision,double precision,integer,public.facility_category[]);
create or replace function public.facilities_within(
  p_lng double precision, p_lat double precision,
  p_radius_m integer default 5000,
  p_categories public.facility_category[] default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision, source varchar, avg_rating numeric, review_count integer
) language sql stable as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m,
         f.source, f.avg_rating, f.review_count
    from public.facilities f
   where f.is_open and f.geom is not null
     and (p_categories is null or f.category = any(p_categories))
     and st_dwithin(f.geom, st_makepoint(p_lng, p_lat)::geography,
                    least(coalesce(p_radius_m, 5000), 5000))
   order by distance_m limit 500;
$$;
grant execute on function public.facilities_within(double precision,double precision,integer,public.facility_category[]) to authenticated, anon;

drop function if exists public.facilities_search(text,double precision,double precision);
create or replace function public.facilities_search(
  p_query text, p_lng double precision default null, p_lat double precision default null
) returns table (
  id uuid, category public.facility_category, name varchar, address text,
  phone varchar, is_open boolean, lng double precision, lat double precision,
  distance_m double precision, source varchar, avg_rating numeric, review_count integer
) language sql stable as $$
  select f.id, f.category, f.name, f.address, f.phone, f.is_open,
         st_x(f.geom::geometry) as lng, st_y(f.geom::geometry) as lat,
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) end as distance_m,
         f.source, f.avg_rating, f.review_count
    from public.facilities f
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name limit 30;
$$;
grant execute on function public.facilities_search(text,double precision,double precision) to authenticated, anon;
