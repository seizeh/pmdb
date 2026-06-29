-- 게시글 작성자 활동지역(동) 표시 + 사용자 활동 범위 설정 (0021). 운영 적용 완료(형상 기록).

-- (1) 게시글 카드에 작성자 활동지역(동)을 보여주기 위해, INSERT 시 트리거가
--     posts.display_address 에 작성자(users.address)의 동 이름을 스탬프한다.
--     (v_post_feed.location = posts.display_address 이므로 피드가 그대로 노출)
create or replace function app.tg_posts_set_region()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_region varchar; v_addr varchar; v_parts text[];
begin
  select region_code, address into v_region, v_addr
    from public.users where id = new.user_id;
  if new.region_code is null then
    new.region_code := v_region;
  end if;
  if new.display_address is null and v_addr is not null and length(btrim(v_addr)) > 0 then
    v_parts := regexp_split_to_array(btrim(v_addr), '\s+');
    new.display_address := v_parts[cardinality(v_parts)]; -- 마지막 토큰 = 동
  end if;
  return new;
end $$;

-- 기존 글 백필(작성자 동)
update public.posts p
set display_address = (regexp_split_to_array(btrim(u.address), '\s+'))[
      cardinality(regexp_split_to_array(btrim(u.address), '\s+'))]
from public.users u
where u.id = p.user_id and p.display_address is null
  and u.address is not null and length(btrim(u.address)) > 0;

-- (2) 사용자 활동 범위(인증 동 기준 반경, 0.5~7km)
alter table public.users add column if not exists activity_radius_m smallint;
alter table public.users drop constraint if exists users_activity_radius_chk;
alter table public.users add constraint users_activity_radius_chk
  check (activity_radius_m is null or activity_radius_m between 500 and 7000);

-- 자기 활동범위 읽기: public_profiles 에 노출(저감도 선호값)
create or replace view public.public_profiles as
  select id, nickname, user_type, profile_image_url, profile_image_thumbnail_url,
         address, is_location_verified, created_at, activity_radius_m
    from public.users u;

-- 설정 RPC(정의자): 동네 인증 필수 + 0.5~7km 상한
create or replace function public.set_activity_radius(p_m integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := app.uid(); v_verified boolean;
begin
  if v_uid is null then raise exception 'activity: 로그인이 필요합니다'; end if;
  select is_location_verified into v_verified from public.users where id = v_uid;
  if not coalesce(v_verified, false) then
    raise exception 'activity: 동네 인증을 먼저 완료해주세요';
  end if;
  if p_m is null or p_m < 500 or p_m > 7000 then
    raise exception 'activity: 활동 범위는 0.5~7km 사이여야 합니다';
  end if;
  update public.users set activity_radius_m = p_m where id = v_uid;
  return p_m;
end $$;
grant execute on function public.set_activity_radius(integer) to authenticated;
