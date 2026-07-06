-- ============================================================================
-- PawMate · 0001 · Extensions & Helper Functions
-- Supabase / PostgreSQL 15 · MVP
-- ----------------------------------------------------------------------------
-- 인증 전제: 본 설계는 "커스텀 JWT 인증"(직접 users 테이블) 기준입니다.
--   - 클라이언트가 들고 오는 JWT는 Supabase 프로젝트 JWT secret 으로 서명하고
--     아래 claim 을 반드시 포함해야 합니다.
--       sub  = users.id (UUID)
--       role = 'authenticated'  (비로그인 요청은 'anon')
--   - PostgREST 가 이 claim 들을 request.jwt.claims 로 노출하므로
--     app.uid() 가 현재 사용자 id 를 돌려줄 수 있습니다.
-- ============================================================================

-- gen_random_uuid()
create extension if not exists pgcrypto;

-- 게시글 제목/본문 부분검색(trigram)
create extension if not exists pg_trgm;

-- 애플리케이션 헬퍼는 public 과 분리된 app 스키마에 둡니다.
create schema if not exists app;

-- ----------------------------------------------------------------------------
-- app.uid() : 현재 요청의 JWT 에서 sub(=users.id) 추출
--   claim 이 없으면(비로그인/마이그레이션 실행 등) NULL 반환.
-- ----------------------------------------------------------------------------
create or replace function app.uid()
returns uuid
language sql
stable
set search_path = ''
as $$
  -- request.jwt.claims 가 NULL 또는 '' 인 경우(비로그인/마이그레이션)를 모두 안전 처리.
  -- 빈 문자열을 곧장 ::jsonb 캐스팅하면 에러가 나므로 먼저 nullif 로 거른다.
  select nullif(
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb) ->> 'sub',
    ''
  )::uuid
$$;

-- ----------------------------------------------------------------------------
-- app.is_admin() : 현재 요청자가 활성 관리자 계정인지.
--   SECURITY DEFINER 로 users 의 RLS 를 우회 → 정책 재귀(recursion) 방지.
-- ----------------------------------------------------------------------------
create or replace function app.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.users u
    where u.id = app.uid()
      and u.user_type = 'admin'
      and u.status = 'active'
  )
$$;

-- ----------------------------------------------------------------------------
-- app.tg_set_updated_at() : updated_at 컬럼 자동 갱신용 공통 트리거 함수
-- ----------------------------------------------------------------------------
create or replace function app.tg_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- 실행 권한: 익명/인증 사용자 모두 헬퍼 함수 호출 가능해야 RLS 정책이 평가됩니다.
grant usage on schema app to anon, authenticated, service_role;
grant execute on function app.uid()       to anon, authenticated, service_role;
grant execute on function app.is_admin()   to anon, authenticated, service_role;
