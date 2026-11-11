-- spatial_ref_sys 쓰기 가드 — API 롤은 막히고, 나머지는 통과하는가.
--
-- 이 가드의 실패 방식은 "잘못 막음" 보다 **"안 막힘"** 이 무섭다. 좌표계 표는 아무도
-- 안 쓰는 것처럼 보여서, 열려 있어도 누가 지우기 전까지 아무 증상이 없다. 그래서
-- 막혀야 할 세 경로(INSERT/UPDATE/DELETE × anon/authenticated)와 열려 있어야 할
-- 경로(운영 롤)를 함께 못 박는다.
--
-- 스냅샷(schema.sql)에는 확장 소유 테이블의 트리거가 안 실린다(pg_dump 제한). 마이그
-- 레이션이 멱등이라 여기서 다시 적용해, 스냅샷 복원 DB 에서도 정본 그대로를 검증한다.
-- TRUNCATE 는 검증하지 않는다 — 롤백되더라도 운영 테이블에 ACCESS EXCLUSIVE 락을 거는
-- 시험은 하지 않는다(같은 트리거·같은 분기라 DML 세 경로로 충분하다).
begin;
set local search_path = public, app, extensions;
\ir ../migrations/20260915100000_spatial_ref_sys_write_guard.sql
select plan(7);

select has_trigger('public', 'spatial_ref_sys', 'spatial_ref_sys_guard',
  '가드 트리거가 걸려 있다');

-- 역할 전환은 throws_ok 의 서브트랜잭션 안에서 일어나므로 예외와 함께 되돌아간다.
-- 대상 행은 존재하지 않는 srid(-1) — 문장 트리거는 0행이어도 발화한다.
select throws_ok(
  $$ set local role anon; delete from public.spatial_ref_sys where srid = -1 $$,
  '42501', 'spatial_ref_sys is read-only for API roles',
  'anon DELETE 는 권한 오류');
select throws_ok(
  $$ set local role anon; update public.spatial_ref_sys set srtext = srtext where srid = -1 $$,
  '42501', 'spatial_ref_sys is read-only for API roles',
  'anon UPDATE 는 권한 오류');
select throws_ok(
  $$ set local role anon;
     insert into public.spatial_ref_sys (srid, auth_name, auth_srid, srtext, proj4text)
     values (-1, 't27', -1, 'x', 'x') $$,
  '42501', 'spatial_ref_sys is read-only for API roles',
  'anon INSERT 는 권한 오류');
select throws_ok(
  $$ set local role authenticated; delete from public.spatial_ref_sys where srid = -1 $$,
  '42501', 'spatial_ref_sys is read-only for API roles',
  'authenticated DELETE 도 권한 오류 — 로그인했다고 열리지 않는다');

-- 운영 롤(이 테스트를 돌리는 롤 = postgres 계열)은 막히지 않는다.
select lives_ok(
  $$ update public.spatial_ref_sys set srtext = srtext where srid = -1 $$,
  '운영 롤의 UPDATE 는 통과 — PostGIS 업그레이드·마이그레이션이 막히면 안 된다');

-- 읽기는 건드리지 않는다 — 거리 연산이 여전히 4326 을 찾는다.
select ok(
  (select count(*) from public.spatial_ref_sys where srid = 4326) = 1,
  'SRID 4326 행이 그대로 읽힌다');

select * from finish();
rollback;
