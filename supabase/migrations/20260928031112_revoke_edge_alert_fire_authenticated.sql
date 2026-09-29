-- edge_alert_fire 는 엣지 함수(service_role)가 알람 원장(app.ops_alarm_fire)에
-- 위임하는 전용 래퍼다(_shared/edge_alert.ts 주석부터 "service_role 전용").
-- 그런데 2026-09-21 통합(20260920062032 계열) 때 생성 기본권한으로 붙은
-- authenticated EXECUTE 를 회수하지 않았다 — 본문에 호출자 검사가 없는
-- definer 라서, 로그인 사용자 누구나 임의 제목·본문의 high 우선순위 알림을
-- 전체 관리자에게 보낼 수 있었다(알람 키가 호출자 입력이라 쿨다운은 스팸을
-- 막지 못한다). 같은 계열 rate_limit_hit·get_password_hash 와 동일하게
-- service_role 전용으로 잠근다. 가드: 주간 점검 ⑭(운영 실측 ↔ 스냅샷 ACL 대조 —
-- pgTAP 은 불가: CI 복원 DB 는 이미지 기본권한이 authenticated 를 재부여한다, #210).
revoke execute on function public.edge_alert_fire(text, text, text, jsonb) from authenticated;
