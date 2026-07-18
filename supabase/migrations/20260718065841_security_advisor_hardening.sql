-- Security advisor 급증 대응 (2026-07-18, advisor 99건 → 76건)
-- 배경:
--  * Supabase 린터에 anon/authenticated_security_definer_function_executable 룰이 새로 추가되어
--    기존 SECURITY DEFINER RPC 들이 일괄 검출됨(급증의 주원인). authenticated 실행은 이 앱의
--    설계(커스텀 JWT + app.uid()/is_admin 내부 게이트)상 의도된 것이므로 유지.
--  * 다만 일부 함수에 PUBLIC/anon 실행권한이 남아 있었고(명시 revoke 누락),
--    7/16 신설 definer 뷰 v_facility_review_comment_feed 에는 public 스키마 기본권한으로
--    anon/authenticated 쓰기권한(INSERT/UPDATE/DELETE/...)까지 부여돼 있었음 — 실제 취약점.

-- 1) SECURITY DEFINER 뷰 쓰기권한 제거 (definer 뷰는 SELECT만 허용 원칙)
revoke insert, update, delete, truncate, references, trigger
  on public.v_facility_review_comment_feed
  from anon, authenticated;

-- 2) anon/PUBLIC 실행권한이 남아있던 RPC 잠금 (authenticated/service_role 유지)
--    앱은 비로그인 상태에서 check_username_available 만 호출하므로 그 외 anon 불필요
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'admin_list_business_applications','admin_ops_metrics',
        'admin_photo_verification_failures','admin_room_messages',
        'admin_set_business_status','admin_set_match_rule',
        'delete_my_chat_message','dong_centroid_seeds','ensure_naver_facility',
        'facilities_search','facilities_within','facility_all_categories',
        'facility_review_by_id','facility_reviews_of','feed_region_codes',
        'naver_facility_id','posts_by_region','public_user_pets',
        'review_owner_switch_hint','update_my_business_info'
      )
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
  end loop;
end$$;

-- 3) rls_auto_enable 은 이벤트 트리거 헬퍼(소유자 권한으로 실행) — API 롤 실행권한 전부 제거
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- 4) app.norm_biz_text search_path 고정 (빌트인만 사용하므로 안전)
alter function app.norm_biz_text(text) set search_path = '';

-- 5) 재발 방지: postgres 가 public 스키마에 만드는 새 함수의 기본 실행권한에서
--    PUBLIC/anon 제거. 이후 새 RPC 는 authenticated/service_role 기본권한만 받으며,
--    anon 이 필요한 경우(가입 전 호출 등)에만 명시적으로 grant 할 것.
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon;

-- 잔여 advisor 항목(수정 불가 또는 의도된 설계, 조치 불필요):
--  * authenticated_security_definer_function_executable 54건: RPC 설계상 의도됨
--  * security_definer_view 5건: 의도된 definer 뷰(쓰기 GRANT 없음 확인)
--  * rls_enabled_no_policy 10건: deny-all 의도(내부 테이블, definer RPC/service_role 전용)
--  * st_estimatedextent(anon) 3건·spatial_ref_sys RLS·extension_in_public 2건:
--    PostGIS/pg_net 확장 소유 객체로 프로젝트 권한으론 변경 불가(읽기 전용, 위험 낮음)
