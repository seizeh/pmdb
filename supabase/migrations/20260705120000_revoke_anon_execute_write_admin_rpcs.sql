-- 로그인/관리자 전용 RPC 에서 anon(비로그인) 실행권한 제거.
--   목적: 최소권한 원칙 + 보안 어드바이저(anon_security_definer_function_executable) 정리.
--   이 함수들은 모두 세션(app.uid()) 또는 관리자(is_admin) 가 필요하며 게스트는 호출하지 않는다.
--   ★ 게스트가 호출하는 조회/인증 RPC(login_user, check_username_available, posts_by_region,
--     feed_region_codes, facility_all_categories, facility_reviews_of, naver_facility_id,
--     ensure_naver_facility, dong_centroid_seeds 등)는 anon 유지 → 건드리지 않는다.
--
--   기본 CREATE FUNCTION 은 EXECUTE 를 PUBLIC 에 부여하므로, anon 을 실제로 막으려면
--   PUBLIC 에서 회수하고 정당한 호출자(authenticated/service_role)에만 재부여해야 한다.

do $$
declare
  r record;
  targets text[] := array[
    -- 쓰기/사용자 전용(로그인 필요)
    'update_my_post', 'delete_my_post', 'create_post_verified',
    'add_facility_review', 'delete_facility_review', 'set_activity_radius',
    'change_password', 'can_manage_post_applicants',
    'register_device_token', 'start_direct_chat',
    -- 관리자 전용(내부 is_admin 게이트로 보호)
    'admin_dashboard_stats', 'admin_get_report_target', 'admin_join_inquiry',
    'admin_list_comments', 'admin_list_inquiries', 'admin_list_logs',
    'admin_list_posts', 'admin_list_reports', 'admin_list_users',
    'admin_set_chat_message_deleted', 'admin_set_comment_deleted',
    'admin_set_post_visibility', 'admin_set_report_status', 'admin_set_user_status'
  ];
begin
  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any(targets)
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end $$;
