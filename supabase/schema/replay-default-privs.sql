-- Supabase 기본 권한 — baseline.sql 다음, 마이그레이션 앞에 적용한다.
--
-- 적용 시점이 중요하다. 베이스라인은 운영의 '최종 ACL' 을 GRANT 문으로 그대로 담고
-- 있으므로 빈 ACL 에서 출발해야 정확히 재현된다. 여기서 먼저 기본 권한을 걸면 그
-- 위에 GRANT 가 얹혀 운영보다 넓어진다(admin_logs 가 SELECT 대신 ALL 이 되는 식).
-- 반대로 마이그레이션이 만드는 객체는 운영에서 이 기본 권한을 받은 상태이므로,
-- 마이그레이션을 돌리기 전에는 걸려 있어야 한다.

-- Supabase 프로젝트는 public 스키마에 기본 권한이 걸려 있어, 새로 만든 테이블이
-- 아무 GRANT 없이도 anon/authenticated/service_role 권한을 갖는다. 맨바닥 DB 에는
-- 없으므로 마이그레이션이 만든 객체의 ACL 이 운영과 달라진다.
--
-- 아래 값은 운영 DB 에서 그대로 읽어온 것이다(pg_default_acl, defaclrole=postgres):
--   테이블   arwdDxtm(ALL)          → postgres, anon, authenticated, service_role
--   시퀀스   rwU(SELECT,UPDATE,USAGE)→ postgres, anon, authenticated, service_role
--   함수     X(EXECUTE)             → postgres, authenticated, service_role  (PUBLIC 없음)
-- app 스키마에는 기본 권한이 걸려 있지 않다(운영도 동일).
alter default privileges in schema public
  grant all on tables to postgres, anon, authenticated, service_role;

alter default privileges in schema public
  grant select, update, usage on sequences to postgres, anon, authenticated, service_role;

-- 함수 기본값에서 PUBLIC 을 먼저 걷어내야 운영과 같아진다
-- (그대로 두면 PUBLIC=EXECUTE 가 남아 REVOKE … FROM PUBLIC 유무로 diff 가 난다).
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public
  grant execute on functions to postgres, authenticated, service_role;

