-- public 의 TRUNCATE/TRIGGER/REFERENCES 를 anon·authenticated 에서 회수
--
-- Supabase 기본권한(default privileges)이 새 테이블마다 anon/authenticated 에 ALL 을
-- 부여해, PostgREST 가 결코 쓰지 않는 세 권한이 잔재로 쌓여 있었다(실측 2026-09-20:
-- authenticated 33개·anon 6개). 셋 다 REST 동사가 없어 오늘의 실행 경로는 없지만:
--   · TRUNCATE 는 RLS 의 적용을 받지 않는다 — SQL 경로가 생기는 순간 정책과 무관하게
--     테이블 전체 소거가 되는 권한이다(스푸핑 아닌 실측 전례: spatial_ref_sys anon DELETE).
--   · TRIGGER 는 EXECUTE 가능한 기존 함수(PUBLIC EXECUTE 기본 부여 — block_user 회수
--     무효 사례의 그 함정)를 남의 테이블/뷰(INSTEAD OF)에 붙일 수 있게 한다.
--   · "왜 남겨놨는가"에 답이 없는 권한은 의도가 아니라 잔재다 — 회수가 답이다.
--
-- service_role 은 대상 아님(BYPASSRLS·도구 의존). supabase_admin 소유 PostGIS 3종
-- (spatial_ref_sys·geometry_columns·geography_columns)은 우리 롤로 회수 불가 —
-- 별도 관리(spatial_ref_sys 는 쓰기 가드 트리거).

do $$
declare r record;
begin
  -- 테이블(및 파티션): 세 권한 전부
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','p')
       and pg_get_userbyid(c.relowner) = 'postgres'
  loop
    execute format(
      'revoke truncate, trigger, references on table public.%I from anon, authenticated',
      r.relname);
  end loop;
  -- 뷰: TRUNCATE 는 뷰에 부여 불가한 권한이므로 TRIGGER/REFERENCES 만
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('v','m')
       and pg_get_userbyid(c.relowner) = 'postgres'
  loop
    execute format(
      'revoke trigger, references on table public.%I from anon, authenticated',
      r.relname);
  end loop;
end $$;

-- 앞으로 생기는 테이블에 세 권한이 기본 부여되지 않게 — 잔재의 재발 구조 자체를 차단.
alter default privileges for role postgres in schema public
  revoke truncate, trigger, references on tables from anon, authenticated;
