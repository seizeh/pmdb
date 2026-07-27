-- 시설 조회 RPC 를 비로그인에 개방 (0029 후속)
--
-- 배경: 20260718065841_security_advisor_hardening.sql 이 이 함수들에서 anon 실행권한을
-- 회수하면서 근거를 이렇게 적었다 —
--   "앱은 비로그인 상태에서 check_username_available 만 호출하므로 그 외 anon 불필요"
--
-- **그 전제가 0029 로 깨졌다.** 매장 QR 로 들어온 손님은 로그인 전에 매장을 찾고
-- 후기를 읽고 남기기까지 한다. 특히 지도는 게스트 모드(MainScreen(isGuest: true))에서
-- 열리는데 facilities_within 이 42501 로 막혀, 마커가 하나도 없이 "주변 시설을
-- 불러오지 못했어요" 라는 **원인과 무관한 오류**만 뜨고 있었다(실제 사용자 신고).
--
-- 안전성: 아래는 전부 **읽기 전용**이고, 드러나는 데이터는 이미 anon 에 공개돼 있다.
--   · facilities 테이블: RLS `using (true)` + anon SELECT
--   · facility_reviews: 공개 후기(visibility_status='visible' 만 반환)
--   · owner_user_id: public_profiles.business_facility_id 로 이미 anon 조회 가능
-- 즉 새로 노출되는 정보 없이 "같은 데이터를 RPC 로도 읽게" 하는 것뿐이다.
--
-- 열지 않는 것(의도적):
--   · ensure_naver_facility — 행을 만드는 **쓰기**다. 게스트가 후기를 쓸 때는
--     간이 인증으로 이미 authenticated 토큰을 들고 있으므로 열 필요가 없다.
--   · posts_by_region / feed_region_codes / dong_centroid_seeds — 지도의 게시글
--     레이어. 시설과 별개 관심사이고 이번 요청 범위가 아니다(게스트가 그 레이어를
--     켜면 여전히 로그인이 필요하다).
--   · facilities_within 의 좌표 인자는 클라이언트가 보는 지도 중심일 뿐이라
--     서버가 위치를 수집하지 않는다 — 웹의 위치 수집 차단 정책과 무관하다.
--
-- ⚠ Supabase 린터의 anon_security_definer_function_executable 경고가 이 함수 수만큼
-- 다시 뜬다. 위 근거대로 **의도된 것**이니 advisor 정리 때 도로 잠그지 말 것.

begin;

grant execute on function
  public.facilities_within(double precision, double precision, integer, facility_category[])
  to anon;

grant execute on function
  public.facility_all_categories(uuid)
  to anon;

grant execute on function
  public.facility_reviews_of(uuid, integer, integer)
  to anon;

grant execute on function
  public.facility_review_by_id(uuid)
  to anon;

commit;
