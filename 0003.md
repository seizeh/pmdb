-- ============================================================================
-- PawMate · 0003 · Indexes
-- Supabase / PostgreSQL 15 · MVP
-- ============================================================================

-- ---------------------------------------------------------------------------
-- users : 대소문자 무관 유일성(lower index). 컬럼 UNIQUE 미사용(중복 회피)
-- ---------------------------------------------------------------------------
create unique index users_lower_username_uq on public.users (lower(username));
create unique index users_lower_email_uq    on public.users (lower(email));
create unique index users_lower_nickname_uq on public.users (lower(nickname));
create index users_user_type_idx on public.users (user_type);

-- ---------------------------------------------------------------------------
-- email_verifications : 조회/rate-limit/만료정리
-- ---------------------------------------------------------------------------
create index email_verifications_lookup_idx
  on public.email_verifications (lower(email), purpose, created_at desc);
create index email_verifications_expires_idx
  on public.email_verifications (expires_at);

-- ---------------------------------------------------------------------------
-- pets
-- ---------------------------------------------------------------------------
create index pets_user_id_idx on public.pets (user_id);
create index pets_active_idx  on public.pets (user_id) where pet_status = 'active';

-- ---------------------------------------------------------------------------
-- posts : 목록/지도/동단위/검색
-- ---------------------------------------------------------------------------
create index posts_list_idx
  on public.posts (visibility_status, progress_status, created_at desc);
create index posts_user_id_idx on public.posts (user_id);
create index posts_region_idx
  on public.posts (region_code, progress_status, created_at desc);
create index posts_category_idx on public.posts (category);
-- trigram 부분검색(제목+본문)
create index posts_trgm_idx
  on public.posts using gin ((coalesce(title,'') || ' ' || coalesce(content,'')) gin_trgm_ops);
-- 지도 박스 검색(MVP 임시) — 공개 좌표 기준
create index posts_display_coord_idx on public.posts (display_lat, display_lng);

-- ---------------------------------------------------------------------------
-- post_views : view_bucket 기반 race-safe 중복 방지(partial unique)
-- ---------------------------------------------------------------------------
create unique index post_views_user_bucket_uq
  on public.post_views (post_id, user_id, view_bucket) where user_id is not null;
create unique index post_views_ip_bucket_uq
  on public.post_views (post_id, ip_hash, view_bucket) where ip_hash is not null;
create index post_views_post_idx   on public.post_views (post_id);
create index post_views_viewed_idx on public.post_views (viewed_at);     -- TTL 정리용

-- ---------------------------------------------------------------------------
-- post_pets / post_likes
-- ---------------------------------------------------------------------------
create index post_pets_pet_idx  on public.post_pets (pet_id);
create index post_likes_user_idx on public.post_likes (user_id);

-- ---------------------------------------------------------------------------
-- applications
-- ---------------------------------------------------------------------------
create index applications_post_status_idx on public.applications (post_id, status);
create index applications_applicant_idx    on public.applications (applicant_id);

-- ---------------------------------------------------------------------------
-- appointments : 활성 약속 1개 보장(partial unique)
-- ---------------------------------------------------------------------------
create unique index appointments_active_post_uq
  on public.appointments (post_id) where status = 'scheduled';
create index appointments_owner_idx     on public.appointments (post_owner_id);
create index appointments_applicant_idx on public.appointments (applicant_id);
create index appointments_post_idx      on public.appointments (post_id);

-- ---------------------------------------------------------------------------
-- comments
-- ---------------------------------------------------------------------------
create index comments_post_idx on public.comments (post_id, created_at) where is_deleted = false;
create index comments_user_idx on public.comments (user_id);

-- ---------------------------------------------------------------------------
-- chat
-- ---------------------------------------------------------------------------
create index chat_rooms_last_msg_idx on public.chat_rooms (last_message_at desc);
create index chat_messages_room_order_idx on public.chat_messages (room_id, created_at, id);
create index chat_room_members_user_idx on public.chat_room_members (user_id);

-- ---------------------------------------------------------------------------
-- reviews / 집계
-- ---------------------------------------------------------------------------
create index reviews_reviewee_idx    on public.reviews (reviewee_id);
create index reviews_appointment_idx on public.reviews (appointment_id);

-- ---------------------------------------------------------------------------
-- pawings
-- ---------------------------------------------------------------------------
create index pawings_following_idx on public.pawings (following_id);

-- ---------------------------------------------------------------------------
-- notifications : (1) 병합용 partial unique  (2) 미읽음 조회용
-- ---------------------------------------------------------------------------
create unique index notifications_group_uq
  on public.notifications (user_id, notification_group_key)
  where is_read = false and notification_group_key is not null;
create index notifications_unread_idx
  on public.notifications (user_id, created_at desc) where is_read = false;
create index notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- device_tokens
-- ---------------------------------------------------------------------------
create index device_tokens_active_idx on public.device_tokens (user_id) where is_active = true;

-- ---------------------------------------------------------------------------
-- reports / admin_logs
-- ---------------------------------------------------------------------------
create index reports_status_idx on public.reports (status);
create index reports_target_idx on public.reports (target_type, target_id);
create index admin_logs_admin_idx  on public.admin_logs (admin_id, created_at desc);
create index admin_logs_target_idx on public.admin_logs (target_type, target_id);

-- ---------------------------------------------------------------------------
-- 확장 예정
-- ---------------------------------------------------------------------------
create index location_verifications_user_idx on public.location_verifications (user_id, created_at desc);
create index facility_cache_coord_idx   on public.facility_cache (lat, lng);
create index facility_cache_category_idx on public.facility_cache (category);
create index facility_cache_expires_idx  on public.facility_cache (expires_at);
