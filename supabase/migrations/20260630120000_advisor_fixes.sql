-- Supabase advisor 경고 정리(운영 적용 완료, 형상 기록).
--   1) function_search_path_mutable: 검색 함수 search_path 고정
--   2) multiple_permissive_policies: facility_cache write 정책에서 SELECT 중복 제거
--   3) public_bucket_allows_listing: 공개 버킷 media 의 광범위 SELECT 정책 제거
--
-- 참고(미수정/의도된 항목):
--   - *_security_definer_function_executable(다수): 커스텀 인증이라 앱이 anon 롤로
--     RPC 를 호출 → DEFINER 함수의 anon/auth EXECUTE 는 구조상 필요. by-design.
--   - security_definer_view(public_profiles, v_post_feed): 큐레이트된 공개 뷰. invoker
--     전환은 베이스 테이블 RLS 재설계가 필요해 보류.
--   - rls_disabled_in_public(spatial_ref_sys): PostGIS 시스템 테이블, 소유권상 불가.
--   - extension_in_public(postgis): 사후 스키마 이동은 의존성 파손 위험으로 보류.
--   - rls_enabled_no_policy(phone/photo_verifications, dong_centroids): 엣지/RPC 전용
--     잠금(정책 없음 = 외부 직접접근 차단)이라 의도된 상태.

-- (1) 검색 함수 search_path 고정(postgis st_*·public 테이블만 참조 → public 으로 충분).
alter function public.facilities_within(
  double precision, double precision, integer, public.facility_category[]
) set search_path = public;

alter function public.facilities_search(
  text, double precision, double precision
) set search_path = public;

-- (2) facility_cache: write(cmd=ALL) 가 public SELECT 와 겹쳐 중복 permissive 경고.
--     INSERT/UPDATE/DELETE 로 분리해 SELECT 중복 제거(관리자 쓰기 유지).
drop policy if exists facility_cache_write on public.facility_cache;
create policy facility_cache_insert on public.facility_cache
  for insert with check (app.is_admin());
create policy facility_cache_update on public.facility_cache
  for update using (app.is_admin()) with check (app.is_admin());
create policy facility_cache_delete on public.facility_cache
  for delete using (app.is_admin());

-- (3) 공개 버킷 media 의 광범위 SELECT 정책 제거.
--     앱은 .list() 미사용 + getPublicUrl(공개 URL, RLS 우회)만 사용 → 영향 없음.
drop policy if exists "media public read" on storage.objects;
