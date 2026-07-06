-- ============================================================================
-- PawMate · 0006 · Supabase Advisor(보안 린트) 보정
-- ----------------------------------------------------------------------------
-- 이미 0001~0005 가 적용된 DB 위에서 멱등(idempotent)하게 실행 가능.
-- 새로 처음부터 적용하는 경우엔 0001/0004/0005 가 이미 같은 내용으로 갱신돼 있어
-- 이 파일을 또 실행해도 안전합니다.
-- ============================================================================

-- ===========================================================================
-- [CRITICAL] Security Definer View · public.public_profiles
-- ---------------------------------------------------------------------------
-- 원인: 뷰가 SECURITY DEFINER(기본값)로 동작 → 뷰 소유자(postgres) 권한으로
--       users 의 RLS 를 우회. 우리 의도(민감 컬럼 제외 공개)대로라면 안전하지만,
--       Advisor 는 "RLS 우회 뷰"를 일괄 CRITICAL 로 표시함.
-- 해결: ① 뷰를 security_invoker 로 바꿔 "조회자 권한"으로 동작시키고
--       ② users 에 '활성 사용자 행은 공개' RLS 를 두되
--       ③ 컬럼 단위 GRANT 로 민감 컬럼(password_hash, email, 좌표 등)은 차단.
--       RLS=행 제어, GRANT=컬럼 제어 → 둘을 조합해 안전하게 공개.
-- ===========================================================================

-- ② users 행 공개 정책 (컬럼은 아래 GRANT 로 제한)
drop policy if exists users_select on public.users;
create policy users_select on public.users
  for select using (
    status = 'active'        -- 활성 사용자: 공개 프로필 조회 허용(컬럼은 GRANT 로 제한)
    or id = app.uid()        -- 본인
    or app.is_admin()        -- 관리자
  );

-- ③ 컬럼 단위 권한: 테이블 전체 SELECT 회수 후 안전 컬럼만 부여
revoke select on public.users from anon, authenticated;
grant select (
  id, username, nickname, user_type,
  profile_image_url, profile_image_thumbnail_url,
  address, is_location_verified, created_at
) on public.users to anon, authenticated;
-- ※ password_hash, email, latitude/longitude, unread_*, push_enabled,
--   email_verified, location_verify_*, deleted_at 등은 부여하지 않음 → 클라이언트 차단.
--   (본인 민감정보 조회/수정은 service_role 경유 권장)

-- ① 뷰를 security_invoker 로 재생성 (WHERE 는 RLS 가 대체하므로 제거 → 안전 컬럼만 참조)
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

-- ===========================================================================
-- [WARN] Function Search Path Mutable · search_path 미고정 함수 8개
-- ---------------------------------------------------------------------------
-- 권장 하드닝: 모든 함수에 search_path 고정(주입 공격 방지). 아래 함수들은
-- NEW/OLD 와 pg_catalog 내장함수(now() 등)만 쓰므로 '' 로 고정해도 안전.
-- ===========================================================================
alter function app.uid()                          set search_path = '';
alter function app.tg_set_updated_at()             set search_path = '';
alter function app.tg_posts_deleted_at()           set search_path = '';
alter function app.tg_posts_validate_transition()  set search_path = '';
alter function app.tg_appointments_before_update() set search_path = '';
alter function app.tg_comments_soft_delete_ts()    set search_path = '';
alter function app.tg_chat_messages_soft_delete_ts() set search_path = '';
alter function app.tg_notifications_read_ts()      set search_path = '';

-- ===========================================================================
-- [WARN] RLS Policy Always True · public.chat_rooms (INSERT with check(true))
-- ---------------------------------------------------------------------------
-- 'true' 는 사실상 무제한 INSERT 허용 → 최소한 로그인 사용자로 제한.
-- (권장: 방 생성은 멤버 등록까지 한 트랜잭션으로 처리하는 RPC/서비스 레이어로)
-- ===========================================================================
drop policy if exists chat_rooms_insert on public.chat_rooms;
create policy chat_rooms_insert on public.chat_rooms
  for insert with check (app.uid() is not null);

-- ===========================================================================
-- [WARN] Extension in Public · pg_trgm  (선택 사항)
-- ---------------------------------------------------------------------------
-- 권장: 확장은 extensions 스키마로 분리. 기존 GIN 인덱스는 opclass 를 OID 로
-- 참조하므로 이동해도 깨지지 않음. Supabase 는 extensions 를 search_path 에 포함.
-- 필요 없으면 이 블록은 건너뛰어도 무방.
-- ===========================================================================
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    execute 'alter extension pg_trgm set schema extensions';
  end if;
exception when others then
  raise notice 'pg_trgm 스키마 이동 건너뜀: %', sqlerrm;  -- extensions 스키마 없으면 무시
end $$;

-- ===========================================================================
-- [WARN] rls_auto_enable() · 우리 코드 아님 (대시보드/외부 생성 추정)
-- ---------------------------------------------------------------------------
-- 자동 적용하지 않음. 아래로 정의를 먼저 확인하고, 출처/용도가 불명확하면 제거:
--   select pg_get_functiondef(oid) from pg_proc where proname = 'rls_auto_enable';
--   -- 불필요하면:  drop function if exists public.rls_auto_enable();
--   -- 남겨둘 경우 최소한 public 실행권한 회수:
--   --   revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
-- ===========================================================================
