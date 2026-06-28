-- 게시글 행정동 클러스터 (0021 §6)
-- 게시글에 작성자의 인증 지역(region_code)을 자동 부여하고, 행정동별 게시글 수를
-- 지도 bbox 내에서 집계한다. 행정동 경계 데이터가 없어 대표 좌표는 같은 동 사용자
-- 좌표 평균으로 근사한다(users.latitude/longitude, 0017). 운영 적용 완료(형상 기록).

-- INSERT 시 작성자 지역 자동 태깅
create or replace function app.tg_posts_set_region()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.region_code is null then
    select region_code into new.region_code
      from public.users where id = new.user_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_posts_set_region on public.posts;
create trigger trg_posts_set_region before insert on public.posts
  for each row execute function app.tg_posts_set_region();

-- 기존 글 백필
update public.posts p set region_code = u.region_code
  from public.users u
 where u.id = p.user_id and p.region_code is null and u.region_code is not null;

-- bbox 내 행정동별 집계 (definer: users 좌표 읽되 집계/대표점만 반환, 개별좌표 비노출)
create or replace function public.posts_by_region(
  p_min_lng double precision, p_min_lat double precision,
  p_max_lng double precision, p_max_lat double precision
) returns table (
  region_code varchar, post_count bigint,
  lng double precision, lat double precision, post_ids uuid[]
)
language sql stable security definer set search_path = '' as $$
  with cen as (
    select region_code, avg(longitude) as lng, avg(latitude) as lat
      from public.users
     where region_code is not null and latitude is not null and longitude is not null
     group by region_code
  )
  select p.region_code, count(*)::bigint as post_count,
         c.lng, c.lat, array_agg(p.id order by p.created_at desc) as post_ids
    from public.posts p
    join cen c on c.region_code = p.region_code
   where p.visibility_status = 'visible'
     and c.lng between p_min_lng and p_max_lng
     and c.lat between p_min_lat and p_max_lat
   group by p.region_code, c.lng, c.lat;
$$;
grant execute on function public.posts_by_region(double precision,double precision,double precision,double precision)
  to authenticated;
