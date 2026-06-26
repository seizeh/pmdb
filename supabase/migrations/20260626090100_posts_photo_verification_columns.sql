-- posts 검증 결과 요약 컬럼 + INSERT 컬럼 화이트리스트 (0018)
--
-- 검증 결과는 압축해 비정규화로 남긴다(피드/관리자용). 이 컬럼들은 클라이언트가
-- 직접 쓰지 못하게 하고, 트리거(SECURITY DEFINER)/RPC 경로로만 채운다.

alter table public.posts
  add column if not exists photo_verification_id uuid
    references public.photo_verifications(id),
  add column if not exists ai_pet_species varchar(10),     -- 'dog' | 'cat'
  add column if not exists is_pet_verified boolean not null default false;

comment on column public.posts.is_pet_verified is
  '서버 검증(촬영위치 일치 + AI 실제 반려동물) 통과 사진으로 작성된 글 (0018)';

-- 0005.md L32 의 table-wide INSERT GRANT(authenticated) 회수 후, 안전 컬럼만 재부여.
-- → photo_verification_id / ai_pet_species / is_pet_verified 는 미부여(클라 위조 차단).
--   해당 컬럼은 app.tg_posts_check_write(definer) 가 토큰 검증 후 채운다.
revoke insert on public.posts from authenticated;
grant insert (
  user_id, category, title, content, scheduled_at,
  image_url, image_mime_type, image_file_size, image_thumbnail_url,
  image_width, image_height
) on public.posts to authenticated;
