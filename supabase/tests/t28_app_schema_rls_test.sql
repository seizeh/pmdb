-- app 스키마 RLS 벨트 전수 — "새 테이블이 벨트 없이 태어나는 것"의 회귀 가드.
--
-- app 의 1·2차 방벽은 PostgREST 미노출 + 테이블 무그랜트이고, 정책 없는 RLS 는
-- 실수 그랜트·노출 스키마 변경·신규 INVOKER 함수에 대한 보험이다. 2026-09-20 점검에서
-- 19개 중 10개(0028 계열 신생 테이블·운영 설정류)가 빠져 있었다 — 민감 9개에만 감아 둔
-- 판단이 이후 테이블에 승계되지 않은 부분 적용(0032 §1 유형). 이 단언이 승계를 강제한다.
--
-- 권한(REVOKE) 단언은 스냅샷 DB 의 이미지 기본권한이 회수를 되살려 여기서 못 잰다
-- (0032 §6.4) — 반면 relrowsecurity 는 pg_dump 가 나르므로 여기서 잴 수 있다.
begin;
set local search_path = public, app, extensions;
select plan(1);

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'app 스키마 모든 테이블에 RLS 벨트 (relrowsecurity=true)'
);

select * from finish();
rollback;
