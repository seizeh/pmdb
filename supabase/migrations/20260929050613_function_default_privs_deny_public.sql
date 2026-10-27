-- 직전(20260929045320)의 마무리 — 프로브 실측으로 드러난 잔여 구멍.
--
-- 스키마 단위 기본권한 항목은 내장 기본값에 **더해질 뿐 내장을 걷어내지 못한다**:
-- 함수의 내장 기본값이 PUBLIC=EXECUTE 라서, 직전 조치 후에도 새 함수 proacl 은
-- {=X, postgres=X, service_role=X} — 명시 revoke 를 잊으면 anon 까지 전원 실행
-- 가능이었다(지금껏 안 터진 건 모든 함수 신설 마이그레이션이 revoke from public
-- 을 명시한 관례 덕). 내장 기본값을 바꾸는 유일한 레버는 전역(무스키마) 항목이다.
--
-- 효과: postgres 가 앞으로 만드는 함수는 모든 스키마에서 PUBLIC EXECUTE 기본
-- 미부여 → public 스키마 신설 함수의 기본 ACL 은 {postgres, service_role} 뿐.
-- 사용자용 RPC 는 명시 grant … to authenticated(관례 그대로), app 스키마 신설
-- 함수를 RLS 정책·invoker 경로에서 쓸 때도 명시 grant 필요(기존 함수 불변).
-- 향후 postgres 소유로 CREATE EXTENSION 시 함수 grant 확인 필요(현 확장은
-- supabase_admin 소유라 무관). 드리프트 가드: 주간 점검 ⑭.
alter default privileges for role postgres
  revoke execute on functions from public;
