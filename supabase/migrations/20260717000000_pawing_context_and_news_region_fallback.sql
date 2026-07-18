-- 업체 소식 피드 미노출 + 업체 팔로우 목록 미표시 수정 (0025 후속).
--
-- (1) 소식 글 지역 폴백: business_region_code 가 없는(레거시/테스트) 승인 업체의
--     글이 region_code NULL 로 저장돼 활동반경 피드 필터(inFilter)에서 사라졌다.
--     작성자의 users.region_code 로 폴백한다(실제 등록 업체는 juso 검색으로 항상
--     지역코드 보유 — 폴백은 예외 대비). display_address 는 폴백하지 않는다
--     (개인 동 이름 비노출 유지).
-- (2) pawings.context: 팔로우한 '얼굴'(personal/business) 기록. 없던 탓에 업체
--     팔로우가 목록(v_pawing)에서 개인 닉네임으로 렌더링돼 "업체가 안 보이고"
--     업체↔개인 연결까지 노출됐다. 업체 팔로우 행은 상호·대표사진으로 표시.

-- (1) 트리거 폴백
create or replace function app.tg_posts_set_region()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_user record;
  v_biz  record;
  v_parts text[];
  v_dong text;
begin
  -- 업체 모드 글(소식): 개인 동네 인증 불필요 — 지역/표시 동은 승인 사업장 기준.
  if new.authored_as = 'business' then
    select business_region_code,
           coalesce(business_address_jibun, business_address) as addr
      into v_biz
      from public.business_profiles
     where user_id = new.user_id and status = 'approved';
    if not found then
      raise exception 'posts: 승인된 업체만 소식을 작성할 수 있어요';
    end if;
    if new.region_code is null then
      -- 사업장 지역코드가 없으면(레거시) 작성자 인증 지역으로 폴백 — NULL 이면
      -- 활동반경 피드 필터에서 글이 사라진다.
      new.region_code := coalesce(
        v_biz.business_region_code,
        (select region_code from public.users where id = new.user_id));
    end if;
    if new.display_address is null and v_biz.addr is not null then
      select t into v_dong
        from unnest(regexp_split_to_array(btrim(v_biz.addr), '\s+'))
             with ordinality as u(t, ord)
       where t ~ '(동|읍|면|가|리)$'
       order by ord limit 1;
      new.display_address := v_dong;
    end if;
    return new;
  end if;

  select region_code, address, is_location_verified, last_verified_at
    into v_user
    from public.users where id = new.user_id;

  if not app.is_admin() then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if new.region_code is null then
    new.region_code := v_user.region_code;
  end if;

  if new.display_address is null and v_user.address is not null
     and length(btrim(v_user.address)) > 0 then
    v_parts := regexp_split_to_array(btrim(v_user.address), '\s+');
    new.display_address := v_parts[cardinality(v_parts)];
  end if;
  return new;
end $$;

-- (1) 데이터 보정: 지역코드 없는 승인 업체 → 소유자 인증 지역으로 채우고,
--     region_code 없는 기존 소식 글 백필.
update public.business_profiles bp
   set business_region_code = u.region_code
  from public.users u
 where u.id = bp.user_id and bp.status = 'approved'
   and bp.business_region_code is null and u.region_code is not null;

update public.posts p
   set region_code = coalesce(bp.business_region_code, u.region_code)
  from public.users u
  left join public.business_profiles bp on bp.user_id = u.id and bp.status = 'approved'
 where p.user_id = u.id and p.authored_as = 'business' and p.region_code is null;

-- (2) 팔로우 얼굴 기록
alter table public.pawings add column if not exists context varchar not null default 'personal'
  check (context in ('personal','business'));

-- v_pawing(내가 팔로우): 업체 팔로우 행은 업체 얼굴 — 상호가 이름 자리, 대표 사진,
-- 개인 닉네임 비노출. 개인 행에는 프로필 사진 추가(검색 타일과 동일 표현).
create or replace view public.v_pawing with (security_invoker = true) as
 select pr.id as user_id,
        (case when p.context = 'business' then coalesce(pr.business_name, '업체')
              else pr.nickname::text end)::character varying(50) as nickname,
        pr.user_type,
        p.created_at,
        (case when p.context = 'business' then pr.business_photo_url
              else pr.profile_image_url end) as profile_image_url,
        (p.context = 'business') as is_business,
        (case when p.context = 'business' then pr.business_name end) as business_name
   from public.pawings p
     join public.public_profiles pr on pr.id = p.following_id
  where p.follower_id = app.uid();

-- v_pawmate(나를 팔로우): 팔로워는 항상 개인 얼굴 — 프로필 사진만 추가.
create or replace view public.v_pawmate with (security_invoker = true) as
 select pr.id as user_id,
        pr.nickname,
        pr.user_type,
        p.created_at,
        (exists ( select 1 from public.pawings me
                   where me.follower_id = app.uid()
                     and me.following_id = p.follower_id)) as i_follow_back,
        pr.profile_image_url
   from public.pawings p
     join public.public_profiles pr on pr.id = p.follower_id
  where p.following_id = app.uid();
