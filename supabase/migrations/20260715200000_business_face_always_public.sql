-- 업체 얼굴 상시 공개 (0026 §2 개정) — "일반 모드 = 업체 오프라인" 결합 해제.
-- 종전: public_profiles 의 업체 필드가 active_mode='business' 일 때만 노출되어,
-- 주인이 일반 모드로 돌아가면 상호 검색·업체 프로필·지도 문의가 통째로 사라졌다.
-- 개정: 승인(approved)만이 공개 조건. active_mode 는 이제 '작성 태그(글·댓글)·
-- 내 화면 얼굴·매칭 차단'만 담당한다. 정체성 연결 비노출은 얼굴 라우팅
-- (진입 맥락)이 담당하므로 모드 게이트 없이도 유지된다.
-- 부수 효과: 업체 모드 중 닉네임 검색 불가 트레이드오프 해소(두 얼굴이 각자 검색됨,
-- 검색은 앱이 얼굴별 2쿼리로 분리).
create or replace view public.public_profiles as
  select u.id, u.nickname, u.user_type, u.profile_image_url, u.profile_image_thumbnail_url,
         u.address, u.is_location_verified, u.created_at, u.activity_radius_m,
         coalesce(bp.status = 'approved', false) as is_business,
         case when bp.status = 'approved' then bp.business_name end as business_name,
         case when bp.status = 'approved' then bp.declared_category end as business_category,
         case when bp.status = 'approved' then bp.business_address end as business_address,
         case when bp.status = 'approved' then bp.business_phone end as business_phone,
         case when bp.status = 'approved' then bp.matched_facility_id end as business_facility_id
    from public.users u
    left join public.business_profiles bp on bp.user_id = u.id;
