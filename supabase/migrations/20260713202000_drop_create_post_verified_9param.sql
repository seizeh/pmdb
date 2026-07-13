-- create_post_verified 9-파라미터(구버전) 오버로드 제거 — 단일화.
--
-- 20260703120000(pet_trust_score) 이후 9/12-파라미터가 공존했고, PostgREST 는
-- named args 9개가 9-파라미터에 정확히 일치해 **구버전을 호출**해 왔다.
-- 구버전에는 신뢰 펫(trust>=3) 검증 생략 로직이 없어, 앱이 촬영을 생략하고
-- p_photo_token=null 로 보내는 신뢰 펫 플로우가 서버에서 항상 실패했다.
--
-- 구버전을 drop 하면 남는 12-파라미터(지역 인증 게이트 + 신뢰 로직 포함)가
-- 기본값으로 9개 인자 호출을 그대로 받으므로 앱 수정 없이 해결된다.

drop function if exists public.create_post_verified(
  character varying, character varying, text, timestamp with time zone,
  uuid[], text, character varying, integer, uuid);
