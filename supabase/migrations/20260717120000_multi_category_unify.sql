-- 다중 카테고리 업체 통합 (병원+미용 병행 등 — 같은 업체가 카테고리별 별도 행)
--
-- LOCALDATA 적재 구조상 한 업체가 카테고리 수만큼 facility 행으로 존재한다
-- (이름+주소 동일 행 7,263개 / 3,483업체). 업체 인증·사진·영업시간·후기가
-- 매칭된 한 행에만 붙어 카테고리 필터/검색에서 같은 가게가 미인증처럼 보이고,
-- 후기가 행별로 분산되며, 셀프 후기 차단(own_facility)을 쌍둥이 행으로 우회할
-- 수 있었다. '같은 업체 = 이름+주소 정확 일치'(facility_all_categories 와 동일
-- 기준, 주소 null 이면 자기 자신만)로 전부 통합한다.
--
-- ① 형제 id 헬퍼 + (name,address) 인덱스
-- ② facilities_within/search — 업주 연동을 형제 전체로, 사진·초점·영업시간은
--    business_profiles 에서 직접(행별 동기화 누락 원천 제거), 평점·후기 수는
--    형제 가중 집계
-- ③ add_facility_review own_facility — 형제 인식(우회 차단)
-- ④ facility_reviews_of — 형제 후기 통합 + 방문 차수(visit_no)도 통합 기준
-- ⑤ delete_facility_review — 형제 행에 달린 내 후기도 삭제 가능
-- ⑥ update_my_business_info — 간판명·전화·영업시간 지도 동기화를 형제 전체로
--    (매칭 행만 개명되면 이름 기준 형제 판정이 끊기는 문제 예방)

create index if not exists facilities_name_addr_idx
  on public.facilities (name, address);

-- ── ① 형제 id (자기 자신 포함) ──────────────────────────────────────────
create or replace function public.facility_sibling_ids(p_id uuid)
returns uuid[]
language sql stable set search_path to 'public'
as $$
  select coalesce(array_agg(s.id), array[p_id])
    from facilities f
    join facilities s
      on s.id = f.id
      or (f.address is not null and s.name = f.name and s.address = f.address)
   where f.id = p_id;
$$;

-- ── ② 지도 RPC (반환 타입 동일 — SECURITY DEFINER 유지) ────────────────
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
         st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) as distance_m,
         f.source,
         coalesce(agg.avg_rating, 0) as avg_rating,
         coalesce(agg.review_count, 0) as review_count,
         ob.photo_url as owner_photo_url,
         coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
         ob.user_id as owner_user_id,
         ob.business_hours,
         ob.reviewed_at as owner_verified_at
    from public.facilities f
    -- 업주: 매칭 행뿐 아니라 이름+주소가 같은 형제 행에도 동일하게 연동.
    left join lateral (
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
        join public.facilities mf on mf.id = bp.matched_facility_id
       where bp.status = 'approved'
         and (bp.matched_facility_id = f.id
              or (f.address is not null
                  and mf.name = f.name and mf.address = f.address))
       order by bp.reviewed_at asc nulls last
       limit 1
    ) ob on true
    -- 평점·후기 수: 형제 행 캐시의 가중 평균/합(어느 행을 열어도 같은 값).
    left join lateral (
      select sum(s.review_count)::int as review_count,
             case when sum(s.review_count) > 0
                  then round(sum(s.avg_rating * s.review_count)::numeric
                             / sum(s.review_count), 1)
             end as avg_rating
        from public.facilities s
       where s.id = f.id
          or (f.address is not null and s.name = f.name and s.address = f.address)
    ) agg on true
   where f.is_open and f.geom is not null
     and (p_categories is null or f.category = any(p_categories))
     and st_dwithin(f.geom, st_makepoint(p_lng, p_lat)::geography,
                    least(coalesce(p_radius_m, 5000), 5000))
   order by distance_m limit 500;
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
         case when p_lng is not null and p_lat is not null
              then st_distance(f.geom, st_makepoint(p_lng, p_lat)::geography) end as distance_m,
         f.source,
         coalesce(agg.avg_rating, 0) as avg_rating,
         coalesce(agg.review_count, 0) as review_count,
         ob.photo_url as owner_photo_url,
         coalesce(ob.photo_align_y, 0)::real as owner_photo_align_y,
         ob.user_id as owner_user_id,
         ob.business_hours,
         ob.reviewed_at as owner_verified_at
    from public.facilities f
    left join lateral (
      select bp.user_id, bp.reviewed_at, bp.photo_url, bp.photo_align_y,
             bp.business_hours
        from public.business_profiles bp
        join public.facilities mf on mf.id = bp.matched_facility_id
       where bp.status = 'approved'
         and (bp.matched_facility_id = f.id
              or (f.address is not null
                  and mf.name = f.name and mf.address = f.address))
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
          or (f.address is not null and s.name = f.name and s.address = f.address)
    ) agg on true
   where f.is_open and f.geom is not null
     and f.name ilike '%' || p_query || '%'
   order by distance_m nulls last, f.name limit 30;
$$;

-- ── ③ 셀프 후기 차단 — 형제 행 우회 봉쇄 ───────────────────────────────
create or replace function public.add_facility_review(
  p_facility uuid,
  p_rating smallint,
  p_body text,
  p_paths text[] default '{}'::text[],
  p_urls text[] default '{}'::text[]
) returns uuid
language plpgsql security definer set search_path to ''
as $$
declare v_uid uuid := app.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;
  if exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_uid
       and bp.status in ('pending', 'approved')
       and bp.matched_facility_id = any(public.facility_sibling_ids(p_facility))
  ) then
    raise exception 'own_facility' using errcode = 'P0001';
  end if;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'))
  returning id into v_id;
  return v_id;
end $$;

-- ── ④ 후기 조회 — 형제 행 후기 통합, 방문 차수도 통합 기준 ──────────────
create or replace function public.facility_reviews_of(
  p_facility uuid, p_limit integer default 20, p_offset integer default 0
) returns table (
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean, visit_no integer
) language sql stable security definer set search_path to ''
as $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.facility_id = any(public.facility_sibling_ids(p_facility))
         and fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$$;

-- ── ⑤ 후기 삭제 — 형제 행에 달린 내 후기도 대상 ────────────────────────
create or replace function public.delete_facility_review(
  p_facility uuid, p_review uuid default null
) returns void
language plpgsql security definer set search_path to ''
as $$
declare v_uid uuid := app.uid();
begin
  if v_uid is null then raise exception 'auth required'; end if;
  update public.facility_reviews
     set visibility_status = 'deleted_by_user', updated_at = now()
   where facility_id = any(public.facility_sibling_ids(p_facility))
     and user_id = v_uid
     and (p_review is null or id = p_review);
end $$;

-- ── ⑥ 업체 정보 수정 — 지도 동기화를 형제 전체로(개명 시 그룹 유지) ─────
create or replace function public.update_my_business_info(
  p_storefront_name text default null,
  p_phone text default null,
  p_email text default null,
  p_hours text default null
) returns void
language plpgsql security definer set search_path to ''
as $$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_name text := nullif(btrim(coalesce(p_storefront_name, '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_email text := nullif(btrim(coalesce(p_email, '')), '');
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;
  if length(coalesce(p_hours, '')) > 100 then
    raise exception 'hours_too_long' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    storefront_name = coalesce(v_name, storefront_name),
    business_phone  = coalesce(v_phone, business_phone),
    contact_email   = coalesce(v_email, contact_email),
    business_hours  = case when p_hours is null then business_hours
                           else nullif(btrim(p_hours), '') end,
    updated_at = now()
  where user_id = v_me;

  -- 지도 동기화 — 매칭 행 + 이름·주소가 같은 형제 행 전체(다중 카테고리).
  -- 형제 판정 전에 개명이 매칭 행에만 적용되면 그룹이 끊기므로 반드시 전체에.
  if v_row.matched_facility_id is not null
     and (v_name is not null or v_phone is not null or p_hours is not null) then
    update public.facilities set
      name = coalesce(v_name, name),
      phone = coalesce(v_phone, phone),
      business_hours = case when p_hours is null then business_hours
                            else nullif(btrim(p_hours), '') end,
      owner_updated_at = now(),
      updated_at = now()
    where id = any(public.facility_sibling_ids(v_row.matched_facility_id));
  end if;
end;
$$;
