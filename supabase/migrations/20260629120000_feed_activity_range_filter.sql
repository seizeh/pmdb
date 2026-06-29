-- 활동범위 기반 게시글 피드 필터 (0021). 운영 적용 완료(형상 기록).
-- 활동범위(인증 동 기준 반경) 안에 있는 동네 게시글만 커뮤니티 피드에 노출.
-- 범위 옵션 변경: 5/7/10/15km (최소 5km, 최대 15km).

-- 기존 범위 밖(예전 1~3km 테스트값) 정리 후 제약 갱신
update public.users set activity_radius_m = null
  where activity_radius_m is not null and activity_radius_m < 5000;
alter table public.users drop constraint if exists users_activity_radius_chk;
alter table public.users add constraint users_activity_radius_chk
  check (activity_radius_m is null or activity_radius_m between 5000 and 15000);

create or replace function public.set_activity_radius(p_m integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := app.uid(); v_verified boolean;
begin
  if v_uid is null then raise exception 'activity: 로그인이 필요합니다'; end if;
  select is_location_verified into v_verified from public.users where id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'activity: 동네 인증을 먼저 완료해주세요';
  end if;
  if p_m is null or p_m < 5000 or p_m > 15000 then
    raise exception 'activity: 활동 범위는 5~15km 사이여야 합니다';
  end if;
  update public.users set activity_radius_m = p_m where id = v_uid;
  return p_m;
end $$;

-- v_post_feed 에 region_code 노출(피드 지역 필터용; 작성자 동, 저감도)
create or replace view public.v_post_feed as
  select p.id, p.category, p.title, p.content, p.user_id,
         pr.nickname as author_nickname, pr.user_type as author_user_type,
         p.created_at, p.scheduled_at, p.display_address as location,
         p.heart_count, p.comment_count, p.view_count, p.progress_status,
         (exists (select 1 from public.post_hearts h
                   where h.post_id = p.id and h.user_id = app.uid())) as hearted,
         p.image_url, p.region_code
    from public.posts p
    left join public.public_profiles pr on pr.id = p.user_id;

-- 내 활동범위 안에 있는(게시글이 존재하는) 행정동 코드들. 미인증/미설정이면 NULL(=필터 없음).
-- 정의자: 사용자 비공개 좌표로 거리 계산하되 region_code 만 반환(좌표 비노출).
-- PostGIS 가 public 에 있어 search_path='' 에서 public. 한정 필요.
create or replace function public.feed_region_codes()
returns text[] language sql stable security definer set search_path = '' as $$
  with me as (
    select latitude as lat, longitude as lng, activity_radius_m as r,
           is_location_verified as v
      from public.users where id = app.uid()
  ),
  uavg as (
    select region_code, avg(longitude) as lng, avg(latitude) as lat
      from public.users
     where region_code is not null and latitude is not null and longitude is not null
     group by region_code
  )
  select case
    when (select r from me) is null
      or not (select coalesce(v,false) from me)
      or (select lat from me) is null then null
    else coalesce((
      select array_agg(distinct p.region_code)
        from public.posts p
        left join public.dong_centroids d on d.region_code = p.region_code
        left join uavg u on u.region_code = p.region_code
        cross join me
       where p.visibility_status = 'visible' and p.region_code is not null
         and coalesce(d.lng, u.lng) is not null
         and public.st_distance(
               public.st_makepoint(coalesce(d.lng,u.lng), coalesce(d.lat,u.lat))::public.geography,
               public.st_makepoint(me.lng, me.lat)::public.geography) <= me.r
    ), array[]::text[])
  end;
$$;
grant execute on function public.feed_region_codes() to authenticated;
