-- 함수 기본권한 deny-by-default — edge_alert_fire 재발 구조 차단(#210 후속).
-- 운영 pg_default_acl(grantor=postgres, public, functions)에 authenticated 가
-- 남아 있어(anon 은 이전 정비에서 이미 부재) 새 public 함수가 생성 즉시 로그인
-- 사용자 실행권을 받았다 — service 전용 함수의 revoke 누락이 조용한 보안 구멍이
-- 되는 구조(20260920045336 이 테이블 T/T/R 에 한 것과 같은 조치의 함수판).
--
-- 이후 규칙: 사용자용 RPC 신설 마이그레이션에 명시 grant execute … to
-- authenticated 필수(기존 관례 그대로 — 최근 함수 신설 마이그레이션 전부 이미
-- 명시 REVOKE/GRANT 동반). 누락의 실패 방향만 '조용한 구멍' → '앱에서 즉시
-- 드러나는 permission denied' 로 반전된다. service_role 기본 부여는 유지(엣지
-- 함수의 백엔드 키 — 신뢰 경계 안). 기존 함수 ACL 은 불변(미래 객체에만 적용).
-- 드리프트 가드: 주간 점검 ⑭.
alter default privileges for role postgres in schema public
  revoke execute on functions from authenticated;
