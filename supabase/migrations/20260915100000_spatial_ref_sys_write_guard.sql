-- spatial_ref_sys 쓰기 차단 — anon/authenticated 가 REST 로 좌표계 참조표를 지울 수 있었다.
--
-- ── 무엇이 열려 있었나 ──────────────────────────────────────────────────
--
-- public.spatial_ref_sys 는 PostGIS 가 설치하는 좌표계(SRID) 참조표다(EPSG 공개
-- 데이터 8,500행). 소유자가 supabase_admin 이고 Supabase 기본권한 상속으로
-- anon/authenticated 에 INSERT/UPDATE/DELETE/TRUNCATE 가 붙어 있으며, 확장 소유라
-- 우리 롤로는 RLS 를 못 켠다. 20260630160000 의 revoke 는 소유자가 아니라서
-- no-op 였다(그 파일에 기록됨). 2026-09-15 재확인: 트랜잭션 안에서 anon 롤로 전환해
-- DELETE 를 실행하면 권한 오류 없이 통과한다.
--
-- 위험은 유출이 아니라 가용성이다. SRID 4326 행을 지우거나 proj4text 를 바꾸면
-- facilities.geom(geography) 의 거리 연산(facilities_within·facilities_search)이
-- 깨진다. publishable 키만 있으면 되는 REST DELETE 한 번이면 충분하다.
--
-- ── 왜 트리거인가 ──────────────────────────────────────────────────────
--
-- revoke 는 소유자(supabase_admin)만 할 수 있다. 대신 postgres 는 이 테이블에
-- TRIGGER 권한이 있다(ACL: postgres=arwdDxtm). BEFORE 문장 트리거는 소유자가 아니어도
-- 걸 수 있고, 트리거 함수는 호출자의 EXECUTE 권한과 무관하게 발화한다(anon 에게
-- EXECUTE 가 없어도 막힌다 — 적용 전 트랜잭션 안에서 실증했다).
--
-- 막는 대상은 API 롤 둘뿐이다. 다음은 전부 그대로 통과한다:
--   · postgres(마이그레이션·pg_cron), service_role(Edge Function)
--   · supabase_admin — PostGIS 업그레이드가 spatial_ref_sys 를 갱신한다
--   · SECURITY DEFINER RPC 내부 — current_user 가 정의자(postgres)다
--   · 백업 복원 — session_replication_role=replica 에서 일반 트리거는 발화하지 않는다
-- 즉 "API 롤이 REST 로 직접 치는 것" 만 정확히 막는다. 읽기는 건드리지 않는다
-- (문장 트리거는 쓰기에만 걸리고, 좌표계 표는 공개 데이터라 읽혀도 무해).
--
-- ── 되돌리기 ────────────────────────────────────────────────────────────
--
-- ⚠️ DROP TRIGGER / DISABLE TRIGGER 는 테이블 소유자만 할 수 있어 postgres 로는
-- 불가(적용 전 실증). 끄려면 함수 본문을 `return null` 만 남기도록 create or replace
-- 하면 된다 — 함수는 postgres 소유라 언제든 바꿀 수 있다. 같은 이유로 트리거 생성은
-- 존재 검사로 감싼다(drop-if-exists 가 안 되므로).
--
-- ── 스냅샷 주의 ─────────────────────────────────────────────────────────
--
-- pg_dump 는 확장 소유 테이블의 트리거를 덤프하지 않는다 → schema.sql 에는 함수만
-- 들어가고 트리거는 안 들어간다. 그래서 트리거는 outofband.txt 로 잡는다
-- (_schema_dump.sh). 테스트(t27)는 이 파일을 \ir 로 재적용해 스냅샷 복원 DB 에서도
-- 같은 것을 검증한다 — 그래서 이 파일은 멱등이어야 한다.
--
-- advisor 의 rls_disabled_in_public 경고는 relrowsecurity 만 보므로 남는다. 경고를
-- 지우려면 PostGIS 를 extensions 스키마로 옮겨야 하는데 facilities.geom 드롭·재생성이
-- 필요해 하지 않는다. 목적은 경고가 아니라 구멍이다.

create or replace function app.spatial_ref_sys_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    raise exception 'spatial_ref_sys is read-only for API roles'
      using errcode = '42501';  -- insufficient_privilege — 클라이언트에는 권한 오류로 보인다
  end if;
  return null;  -- 문장 트리거의 반환값은 무시된다
end
$$;

do $$
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.spatial_ref_sys'::regclass
       and tgname = 'spatial_ref_sys_guard'
       and not tgisinternal
  ) then
    create trigger spatial_ref_sys_guard
      before insert or update or delete or truncate on public.spatial_ref_sys
      for each statement execute function app.spatial_ref_sys_guard();
  end if;
end $$;
