-- public_profiles 뷰에 개인 얼굴 통계(받은 후기·Pawing·Pawmate) 추가
--
-- 사용자 검색 타일에서 개인 프로필은 인증 배지 자리에 아무것도 없었다 —
-- 그 자리에 받은 후기·Pawing·Pawmate 수를 보여주기 위한 카운트.
-- Pawing/Pawmate 는 개인 얼굴(context='personal') 기준(얼굴 분리, 0026).
-- 뷰 컬럼이라 select 하지 않는 호출부(fetchProfile 등)는 계산되지 않는다.

create or replace view public.public_profiles as
 select u.id,
    u.nickname,
    u.user_type,
    u.profile_image_url,
    u.profile_image_thumbnail_url,
    u.address,
    u.is_location_verified,
    u.created_at,
    u.activity_radius_m,
    coalesce(bp.status::text = 'approved', false) as is_business,
    case when bp.status::text = 'approved' then bp.business_name end as business_name,
    case when bp.status::text = 'approved' then bp.declared_category end as business_category,
    case when bp.status::text = 'approved' then bp.business_address end as business_address,
    case when bp.status::text = 'approved' then bp.business_phone end as business_phone,
    case when bp.status::text = 'approved' then bp.matched_facility_id end as business_facility_id,
    case when bp.status::text = 'approved' then bp.photo_url end as business_photo_url,
    case when bp.status::text = 'approved' then bp.business_hours end as business_hours,
    (select count(*) from public.reviews r where r.reviewee_id = u.id)::int as review_count,
    (select count(*) from public.pawings p
      where p.follower_id = u.id and p.context = 'personal')::int as pawing_count,
    (select count(*) from public.pawings p
      where p.following_id = u.id and p.context = 'personal')::int as pawmate_count
   from public.users u
   left join public.business_profiles bp on bp.user_id = u.id;
