-- 업체 얼굴의 프로필 사진 = 대표 사진 (0026 §2 보강).
-- 종전에는 업체 얼굴 화면(프로필·검색·업체 문의 방)이 개인 프로필 사진을 빌려 써서
-- ① 같은 사진이 두 얼굴을 잇는 연결 노출이었고 ② "업체 사진을 어디서 바꾸나"가
-- 모호했다(내정보에서 바꿔도 안 바뀌는 혼란). 업체 얼굴은 대표 사진(photo_url)만 쓴다.

-- public_profiles: 업체 대표 사진 노출(승인 상시 — 얼굴 공개 조건과 동일)
create or replace view public.public_profiles as
  select u.id, u.nickname, u.user_type, u.profile_image_url, u.profile_image_thumbnail_url,
         u.address, u.is_location_verified, u.created_at, u.activity_radius_m,
         coalesce(bp.status = 'approved', false) as is_business,
         case when bp.status = 'approved' then bp.business_name end as business_name,
         case when bp.status = 'approved' then bp.declared_category end as business_category,
         case when bp.status = 'approved' then bp.business_address end as business_address,
         case when bp.status = 'approved' then bp.business_phone end as business_phone,
         case when bp.status = 'approved' then bp.matched_facility_id end as business_facility_id,
         case when bp.status = 'approved' then bp.photo_url end as business_photo_url
    from public.users u
    left join public.business_profiles bp on bp.user_id = u.id;

-- v_chat_rooms: 업체 문의 방의 상대 이미지도 대표 사진으로(개인 사진 비노출)
create or replace view public.v_chat_rooms as
 select r.id,
    r.last_message_preview,
    r.last_message_at,
    coalesce(( select case when r.context = 'business' and m2.user_id = r.business_user_id
                           then coalesce(bp.business_name, pr.nickname::text)
                           else pr.nickname::text end
           from chat_room_members m2
             join public_profiles pr on pr.id = m2.user_id
             join users u2 on u2.id = m2.user_id
             left join business_profiles bp
               on bp.user_id = m2.user_id and bp.status = 'approved'
          where m2.room_id = r.id and m2.user_id <> app.uid()
            and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
         limit 1),
        case
            when r.room_type::text = 'admin_inquiry'::text then '고객센터'::text
            else '알 수 없음'::text
        end) as other_nickname,
    ( select m2.user_id
           from chat_room_members m2
             join users u2 on u2.id = m2.user_id
          where m2.room_id = r.id and m2.user_id <> app.uid()
            and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
         limit 1) as other_user_id,
    ( select count(*) as count
           from chat_messages cm
          where cm.room_id = r.id and cm.is_deleted = false and cm.sender_id <> app.uid()
            and (m.last_read_message_id is null or cm.created_at > (( select lr.created_at
                   from chat_messages lr
                  where lr.id = m.last_read_message_id)))) as unread_count,
    (exists ( select 1
           from chat_room_members m3
          where m3.room_id = r.id and m3.user_id <> app.uid() and m3.left_at is not null)) as other_left,
    ( select case when r.context = 'business' and m2.user_id = r.business_user_id
                  then bp.photo_url
                  else pr.profile_image_url end
           from chat_room_members m2
             join public_profiles pr on pr.id = m2.user_id
             join users u2 on u2.id = m2.user_id
             left join business_profiles bp
               on bp.user_id = m2.user_id and bp.status = 'approved'
          where m2.room_id = r.id and m2.user_id <> app.uid()
            and (r.room_type::text <> 'admin_inquiry'::text or u2.user_type::text <> 'admin'::text)
         limit 1) as other_profile_image_url,
    r.context
   from chat_room_members m
     join chat_rooms r on r.id = m.room_id
  where m.user_id = app.uid() and m.left_at is null;
