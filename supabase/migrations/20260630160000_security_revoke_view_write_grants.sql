-- 보안 수정(CRITICAL): SECURITY DEFINER 뷰를 통한 무인증 권한 상승 차단. 운영 적용 완료(형상 기록).
--
-- 배경:
--   직전 advisor 정리(20260630120000)에서 security_definer_view(public_profiles,
--   v_post_feed)를 "큐레이트된 공개 읽기 뷰"로 보고 보류했으나, 실제로는
--     · public_profiles 가 단일 테이블 기반이라 자동 업데이트 가능(INS/UPD/DEL)
--     · 소유자 postgres(BYPASSRLS) → 뷰 경유 시 users 의 RLS·컬럼권한 전부 우회
--     · anon/authenticated 에 뷰 INSERT/UPDATE/DELETE 권한이 부여돼 있었음
--   세 조건이 겹쳐, 공개 anon 키만으로 다음이 가능했음(로그인 불필요):
--     PATCH /rest/v1/public_profiles?id=eq.<victim>  { "user_type": "admin" }
--   → 임의 계정 관리자 승격(app.is_admin() 통과), is_location_verified 셀프 설정으로
--     동네인증/verify-location 무력화, 닉네임·프로필·주소 변조, DELETE 로 계정 삭제.
--   role=anon 으로 실증 확인함(수정 후 'permission denied for view public_profiles').
--
-- 조치: 노출 뷰 전체에서 쓰기 권한 회수 후 SELECT 만 허용. spatial_ref_sys 쓰기도 회수.
--   (뷰는 그대로 정의자 유지 — 익스플로잇 핵심인 '쓰기 경로'만 제거하면 충분.)

revoke insert, update, delete, truncate, references, trigger
  on public.public_profiles, public.v_post_feed,
     public.v_chat_rooms, public.v_comment_feed,
     public.v_pawing, public.v_pawmate
  from anon, authenticated;

grant select
  on public.public_profiles, public.v_post_feed,
     public.v_chat_rooms, public.v_comment_feed,
     public.v_pawing, public.v_pawmate
  to anon, authenticated;

-- 부수: PostGIS 기준 테이블(좌표변환 SRID) 변조/TRUNCATE 차단(무결성·DoS 방어).
revoke insert, update, delete, truncate on public.spatial_ref_sys from anon, authenticated;
