-- ============================================================================
-- PawMate · 0005 · RLS Policies, Public View, Grants
-- Supabase / PostgreSQL 15 · MVP  (문서 15장 RLS 매트릭스 기준)
-- ----------------------------------------------------------------------------
-- 전제: 커스텀 JWT 의 role claim 이 'authenticated' / 'anon'.
--       service_role 은 RLS 를 우회(회원가입·시스템 알림·룸 생성 등 서버 작업).
--       현재 사용자 = app.uid(), 관리자 = app.is_admin().
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 채팅방 멤버 여부 헬퍼 (RLS 자기참조 재귀 방지용 SECURITY DEFINER)
-- ---------------------------------------------------------------------------
create or replace function app.is_room_member(p_room uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.chat_room_members m
    where m.room_id = p_room and m.user_id = app.uid()
  )
$$;
grant execute on function app.is_room_member(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 스키마/테이블 권한 (행 접근은 RLS 가 추가로 제한)
-- ---------------------------------------------------------------------------
grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to anon, authenticated;
grant insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
-- 비로그인 조회수 기록을 위해 anon 에 한정 insert 허용
grant insert on public.post_views to anon;

-- users 는 테이블 전체 SELECT 를 회수하고 안전 컬럼만 컬럼단위로 부여.
-- (행 제어는 RLS, 컬럼 제어는 GRANT — 둘을 조합해 민감 컬럼 노출 차단)
revoke select on public.users from anon, authenticated;
grant select (
  id, username, nickname, user_type,
  profile_image_url, profile_image_thumbnail_url,
  address, is_location_verified, created_at
) on public.users to anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS 활성화 (모든 public 테이블)
-- ---------------------------------------------------------------------------
alter table public.users                   enable row level security;
alter table public.email_verifications     enable row level security;
alter table public.pets                    enable row level security;
alter table public.business_profiles       enable row level security;
alter table public.posts                   enable row level security;
alter table public.post_pets               enable row level security;
alter table public.post_views              enable row level security;
alter table public.post_likes              enable row level security;
alter table public.applications            enable row level security;
alter table public.appointments            enable row level security;
alter table public.comments                enable row level security;
alter table public.chat_rooms              enable row level security;
alter table public.chat_messages           enable row level security;
alter table public.chat_room_members       enable row level security;
alter table public.chat_message_deletions  enable row level security;
alter table public.reviews                 enable row level security;
alter table public.review_category_counts  enable row level security;
alter table public.pawings                 enable row level security;
alter table public.notifications           enable row level security;
alter table public.device_tokens           enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.reports                 enable row level security;
alter table public.admin_logs              enable row level security;
alter table public.location_verifications  enable row level security;
alter table public.user_blocks             enable row level security;
alter table public.facility_cache          enable row level security;

-- ===========================================================================
-- users : 활성 사용자 행은 공개(컬럼은 위 GRANT 로 제한), 본인/admin 은 전 행.
--         민감 컬럼은 컬럼 GRANT 미부여로 차단. 가입/insert 는 service_role.
-- ===========================================================================
create policy users_select on public.users
  for select using (status = 'active' or id = app.uid() or app.is_admin());
create policy users_update on public.users
  for update using (id = app.uid() or app.is_admin())
             with check (id = app.uid() or app.is_admin());

-- ===========================================================================
-- email_verifications : 클라이언트 접근 전면 차단(정책 없음). service_role 만.
-- ===========================================================================

-- ===========================================================================
-- pets : 공개 조회(삭제 제외), 소유자 관리
-- ===========================================================================
create policy pets_select on public.pets
  for select using (pet_status <> 'deleted' or user_id = app.uid() or app.is_admin());
create policy pets_insert on public.pets
  for insert with check (user_id = app.uid());
create policy pets_update on public.pets
  for update using (user_id = app.uid() or app.is_admin())
             with check (user_id = app.uid() or app.is_admin());

-- ===========================================================================
-- business_profiles : 공개 조회, 본인/admin 관리
-- ===========================================================================
create policy business_profiles_select on public.business_profiles
  for select using (true);
create policy business_profiles_insert on public.business_profiles
  for insert with check (user_id = app.uid() or app.is_admin());
create policy business_profiles_update on public.business_profiles
  for update using (user_id = app.uid() or app.is_admin())
             with check (user_id = app.uid() or app.is_admin());

-- ===========================================================================
-- posts
-- ===========================================================================
create policy posts_select on public.posts
  for select using (
    visibility_status = 'visible'
    or (visibility_status = 'hidden_by_user' and user_id = app.uid())
    or app.is_admin()
  );
create policy posts_insert on public.posts
  for insert with check (user_id = app.uid());
create policy posts_update on public.posts
  for update using (user_id = app.uid() or app.is_admin())
             with check (user_id = app.uid() or app.is_admin());
create policy posts_delete on public.posts
  for delete using (app.is_admin());

-- ===========================================================================
-- post_pets : 게시글 가시성 따라 조회, 작성자 관리
-- ===========================================================================
create policy post_pets_select on public.post_pets
  for select using (
    exists (select 1 from public.posts p
            where p.id = post_id
              and (p.visibility_status = 'visible' or p.user_id = app.uid() or app.is_admin()))
  );
create policy post_pets_insert on public.post_pets
  for insert with check (
    exists (select 1 from public.posts p where p.id = post_id and p.user_id = app.uid())
  );
create policy post_pets_delete on public.post_pets
  for delete using (
    exists (select 1 from public.posts p where p.id = post_id and p.user_id = app.uid())
    or app.is_admin()
  );

-- ===========================================================================
-- post_views : 조회는 admin/통계, 기록은 누구나(본인 또는 익명 ip)
-- ===========================================================================
create policy post_views_select on public.post_views
  for select using (app.is_admin());
create policy post_views_insert on public.post_views
  for insert with check (user_id is null or user_id = app.uid());

-- ===========================================================================
-- post_likes : 공개 조회, 본인 토글
-- ===========================================================================
create policy post_likes_select on public.post_likes
  for select using (true);
create policy post_likes_insert on public.post_likes
  for insert with check (user_id = app.uid());
create policy post_likes_delete on public.post_likes
  for delete using (user_id = app.uid());

-- ===========================================================================
-- applications : 게시글 작성자 + 지원자 + admin
-- ===========================================================================
create policy applications_select on public.applications
  for select using (
    applicant_id = app.uid()
    or exists (select 1 from public.posts p where p.id = post_id and p.user_id = app.uid())
    or app.is_admin()
  );
create policy applications_insert on public.applications
  for insert with check (applicant_id = app.uid());
create policy applications_update on public.applications
  for update using (
    applicant_id = app.uid()
    or exists (select 1 from public.posts p where p.id = post_id and p.user_id = app.uid())
    or app.is_admin()
  );

-- ===========================================================================
-- appointments : 당사자 + admin (INSERT 는 수락 트리거=definer 로만)
-- ===========================================================================
create policy appointments_select on public.appointments
  for select using (post_owner_id = app.uid() or applicant_id = app.uid() or app.is_admin());
create policy appointments_update on public.appointments
  for update using (post_owner_id = app.uid() or applicant_id = app.uid() or app.is_admin())
             with check (post_owner_id = app.uid() or applicant_id = app.uid() or app.is_admin());

-- ===========================================================================
-- comments
-- ===========================================================================
create policy comments_select on public.comments
  for select using (is_deleted = false or app.is_admin());
create policy comments_insert on public.comments
  for insert with check (user_id = app.uid());
create policy comments_update on public.comments
  for update using (user_id = app.uid() or app.is_admin())
             with check (user_id = app.uid() or app.is_admin());

-- ===========================================================================
-- chat_rooms : 멤버 + admin
-- ===========================================================================
create policy chat_rooms_select on public.chat_rooms
  for select using (app.is_room_member(id) or app.is_admin());
create policy chat_rooms_insert on public.chat_rooms
  for insert with check (app.uid() is not null);  -- 로그인 사용자만. 멤버 등록까지는 RPC/서버 권장
create policy chat_rooms_update on public.chat_rooms
  for update using (app.is_admin());

-- ===========================================================================
-- chat_messages : 방 멤버만 조회/전송, admin 만 soft delete
-- ===========================================================================
create policy chat_messages_select on public.chat_messages
  for select using (app.is_room_member(room_id) or app.is_admin());
create policy chat_messages_insert on public.chat_messages
  for insert with check (sender_id = app.uid() and app.is_room_member(room_id));
create policy chat_messages_update on public.chat_messages
  for update using (app.is_admin());

-- ===========================================================================
-- chat_room_members : 본인/같은 방 멤버 조회, 본인 읽음 갱신
-- ===========================================================================
create policy chat_room_members_select on public.chat_room_members
  for select using (user_id = app.uid() or app.is_room_member(room_id) or app.is_admin());
create policy chat_room_members_insert on public.chat_room_members
  for insert with check (user_id = app.uid() or app.is_admin());
create policy chat_room_members_update on public.chat_room_members
  for update using (user_id = app.uid())
             with check (user_id = app.uid());

-- ===========================================================================
-- chat_message_deletions : 본인 기준 숨김
-- ===========================================================================
create policy chat_message_deletions_select on public.chat_message_deletions
  for select using (user_id = app.uid());
create policy chat_message_deletions_insert on public.chat_message_deletions
  for insert with check (user_id = app.uid());

-- ===========================================================================
-- reviews : 전체 공개 조회, 작성자 본인만 INSERT(트리거가 당사자/완료 검증), 불변
-- ===========================================================================
create policy reviews_select on public.reviews
  for select using (true);
create policy reviews_insert on public.reviews
  for insert with check (reviewer_id = app.uid());

-- ===========================================================================
-- review_category_counts : 공개 조회(집계는 트리거=definer 만 기록)
-- ===========================================================================
create policy review_category_counts_select on public.review_category_counts
  for select using (true);

-- ===========================================================================
-- pawings : 공개 조회, 본인 팔로우/취소
-- ===========================================================================
create policy pawings_select on public.pawings
  for select using (true);
create policy pawings_insert on public.pawings
  for insert with check (follower_id = app.uid());
create policy pawings_delete on public.pawings
  for delete using (follower_id = app.uid());

-- ===========================================================================
-- notifications : 본인 + admin
-- ===========================================================================
create policy notifications_select on public.notifications
  for select using (user_id = app.uid() or app.is_admin());
create policy notifications_insert on public.notifications
  for insert with check (app.is_admin());      -- 일반 알림은 service_role/트리거 경로
create policy notifications_update on public.notifications
  for update using (user_id = app.uid() or app.is_admin())
             with check (user_id = app.uid() or app.is_admin());

-- ===========================================================================
-- device_tokens : 본인만
-- ===========================================================================
create policy device_tokens_all on public.device_tokens
  for all using (user_id = app.uid()) with check (user_id = app.uid());

-- ===========================================================================
-- notification_preferences : 본인만
-- ===========================================================================
create policy notification_preferences_all on public.notification_preferences
  for all using (user_id = app.uid()) with check (user_id = app.uid());

-- ===========================================================================
-- reports : 본인 신고 + admin. INSERT 본인, UPDATE admin.
-- ===========================================================================
create policy reports_select on public.reports
  for select using (reporter_id = app.uid() or app.is_admin());
create policy reports_insert on public.reports
  for insert with check (reporter_id = app.uid());
create policy reports_update on public.reports
  for update using (app.is_admin()) with check (app.is_admin());

-- ===========================================================================
-- admin_logs : admin 만 조회 (INSERT 는 트리거=definer)
-- ===========================================================================
create policy admin_logs_select on public.admin_logs
  for select using (app.is_admin());

-- ===========================================================================
-- location_verifications : 본인 + admin
-- ===========================================================================
create policy location_verifications_select on public.location_verifications
  for select using (user_id = app.uid() or app.is_admin());
create policy location_verifications_insert on public.location_verifications
  for insert with check (user_id = app.uid());

-- ===========================================================================
-- user_blocks : 본인(차단 주체)만
-- ===========================================================================
create policy user_blocks_select on public.user_blocks
  for select using (blocker_id = app.uid());
create policy user_blocks_insert on public.user_blocks
  for insert with check (blocker_id = app.uid());
create policy user_blocks_delete on public.user_blocks
  for delete using (blocker_id = app.uid());

-- ===========================================================================
-- facility_cache : 공개 조회 (쓰기는 service_role/admin)
-- ===========================================================================
create policy facility_cache_select on public.facility_cache
  for select using (true);
create policy facility_cache_write on public.facility_cache
  for all using (app.is_admin()) with check (app.is_admin());

-- ===========================================================================
-- public_profiles VIEW : 민감 컬럼(password_hash, email 등) 제외 공개 프로필
--   security_invoker=on → 조회자 권한으로 동작(Advisor CRITICAL 회피).
--   행 필터(status='active')는 users RLS 가 담당하므로 WHERE 불필요.
--   참조 컬럼은 모두 위에서 anon/authenticated 에 GRANT 한 안전 컬럼뿐.
-- ===========================================================================
create or replace view public.public_profiles
  with (security_invoker = on) as
  select
    u.id,
    u.username,
    u.nickname,
    u.user_type,
    u.profile_image_url,
    u.profile_image_thumbnail_url,
    u.address,
    u.is_location_verified,
    u.created_at
  from public.users u;

grant select on public.public_profiles to anon, authenticated;
