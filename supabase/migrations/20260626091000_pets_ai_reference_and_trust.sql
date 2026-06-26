-- 펫 AI 인증 기준 사진 + 개체 일치 신뢰도 (0019)
--
-- ai_ref_*  : 카메라+실존+위치 파이프라인을 통과한 "AI 인증용 기준 사진"(대표사진과 별개).
--             게시글 사진 개체 대조의 기준이 된다. 서버(definer)만 기록.
-- pet_match_count : 검증 카테고리 게시글에서 개체 일치(matched)가 누적된 횟수 → 신뢰도.

alter table public.pets
  add column if not exists ai_ref_image_url       text,
  add column if not exists ai_ref_image_path      text,
  add column if not exists ai_ref_verification_id  uuid references public.photo_verifications(id),
  add column if not exists ai_ref_verified_at      timestamptz,
  add column if not exists pet_match_count         integer not null default 0;

comment on column public.pets.ai_ref_image_path is
  'AI 인증 기준 사진의 media 경로(개체 대조 baseline). 대표사진 image_url 과 별개 (0019)';
comment on column public.pets.pet_match_count is
  '검증 카테고리 게시글에서 개체 일치가 누적된 횟수(펫 신뢰도) (0019)';

-- 0005 의 table-wide INSERT/UPDATE GRANT 때문에 컬럼 단위 revoke 가 안 먹는다.
-- → 테이블 권한 회수 후 "사용자가 직접 편집 가능한 컬럼"만 화이트리스트로 재부여.
--   ai_ref_* / pet_match_count 는 미부여 → 트리거/RPC(definer)만 기록(클라 위조 차단).
revoke insert, update on public.pets from authenticated;

grant insert (
  primary_guardian_id, name, species, gender, birth_date, is_neutered, bio,
  image_url, image_thumbnail_url, image_mime_type, image_file_size, image_width, image_height
) on public.pets to authenticated;

grant update (
  name, species, gender, birth_date, is_neutered, bio, pet_status,
  image_url, image_thumbnail_url, image_mime_type, image_file_size, image_width, image_height
) on public.pets to authenticated;
