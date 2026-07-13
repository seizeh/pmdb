-- 반려동물 신원 인증(enroll-pet-identity) 실패도 photo_verifications 에 기록하기 위해
-- purpose CHECK 에 'pet_identity' 허용값 추가. (기존: reference | post)
-- 신원 인증 실패는 지금까지 어떤 기록도 남지 않아 관리자 실패 조회
-- (admin_photo_verification_failures)에서 보이지 않던 공백의 선행 작업.
alter table public.photo_verifications drop constraint photo_verifications_purpose_check;
alter table public.photo_verifications add constraint photo_verifications_purpose_check
  check ((purpose)::text = any (array['reference','post','pet_identity']::text[]));
