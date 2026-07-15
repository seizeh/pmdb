-- 지도 시설 RPC 의 owner_user_id 가 앱에서 항상 NULL 이던 버그 수정.
--
-- facilities_within / facilities_search 는 INVOKER 함수라 내부의
-- business_profiles 서브쿼리(매칭 업주 uid)가 호출자 RLS 로 실행된다.
-- business_profiles 에는 본인 행만 보이는 정책(business_profiles_select_own)뿐이라
-- 앱(authenticated)에서는 owner_user_id 가 전 시설 NULL → 지도 상세 히어로 탭
-- '업체 프로필' 진입이 아무에게도 동작하지 않았다(사진 owner_photo_url 은
-- facilities 동기화 컬럼이라 히어로 자체는 보임 — 탭만 무반응).
--
-- 승인(approved) 업체의 지도-업주 연결은 공개 정보다(0026: 업체 얼굴은 승인만이
-- 공개 조건). 두 함수를 SECURITY DEFINER 로 전환해 RLS 와 무관하게 반환한다.
-- 함수는 읽기 전용이고 search_path 는 이미 public 으로 고정돼 있다.
-- (business_profiles 테이블 자체의 RLS/grants 는 그대로 — 민감 컬럼 노출 없음.)

alter function public.facilities_within(
  double precision, double precision, integer, facility_category[]
) security definer;

alter function public.facilities_search(
  text, double precision, double precision
) security definer;
