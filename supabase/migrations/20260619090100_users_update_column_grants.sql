-- 0017 지역 인증 — users UPDATE 컬럼 권한 정리 (보안).
--
-- 라이브 DB 실측(2026-06-19): authenticated 는 테이블 전체 UPDATE 가 아니라
-- 컬럼 단위 UPDATE 만 보유한다 — address, nickname, profile_image_url,
-- profile_image_thumbnail_url, profile_image_mime_type, profile_image_file_size,
-- push_enabled. 즉 is_location_verified / region_code / latitude / longitude /
-- last_verified_at / location_verify_* 는 이미 클라 쓰기 불가 상태다.
--
-- 다만 address(인증 동네 표시 라벨)가 클라 UPDATE 가능으로 남아 있다. address 는
-- 동네 인증 RPC(record_location_verification)만 세팅해야 하므로(0017) 회수한다.
-- 클라이언트의 users UPDATE 사용처는 profile_repository.updateProfile 의
-- nickname / profile_image_url 뿐임을 전수 확인했다(pmdart) → address 회수는 무영향.
--
-- revoke update(테이블 전체)는 방어적 멱등 처리(현재 테이블 단위 grant 는 없음).
revoke update on public.users from authenticated;
revoke update (address) on public.users from authenticated;

grant update (
  nickname,
  profile_image_url,
  profile_image_thumbnail_url,
  profile_image_mime_type,
  profile_image_file_size,
  push_enabled
) on public.users to authenticated;

-- (선택) 만료 표시용으로 last_verified_at 읽기 허용.
grant select (last_verified_at) on public.users to authenticated;
