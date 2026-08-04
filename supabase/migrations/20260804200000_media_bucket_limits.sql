-- media 버킷에 MIME·용량 제한 — 공개 CDN 이 임의 파일 호스팅이 되지 않게 (0032 §9.2).
--
-- media 는 **공개 버킷**이다. 객체 URL 을 아는 누구나 인증 없이 받아 갈 수 있고,
-- 저장된 content-type 이 응답 헤더로 **그대로** 나간다(2026-08-04 실측: 공개 URL 에
-- `X-Content-Type-Options: nosniff` 도, `Content-Disposition` 도 없다).
--
-- 그런데 버킷에 allowed_mime_types 도 file_size_limit 도 없었다. 쓰기 통제는
-- 경로 규약(`<uid>/...`)뿐이라, 로그인한 누구나 **자기 폴더에** 무엇이든 올릴 수 있었다:
--
--   · `text/html` 로 올리면 supabase.co 도메인에서 **살아 있는 HTML 페이지**가 된다(피싱).
--   · `image/svg+xml` 은 스크립트를 품을 수 있어 이미지처럼 보이지만 XSS 가 된다.
--   · 크기 상한이 없어 한 객체로 저장소를 얼마든지 채울 수 있다(앱의 100MB 는
--     클라이언트 검사라 REST 직접 호출로 우회된다).
--
-- 앱 코드가 얌전한 것과 별개다. 엣지 함수 두 곳(enroll-pet-identity·verify-post-photo)은
-- **클라이언트가 보낸 mimeType 을 그대로 contentType 으로** 넘기기까지 했다.
-- 그래서 검증을 호출부마다 흩지 않고 **모든 업로드가 지나는 한 곳**(버킷)에 둔다.
--
-- ── 허용 목록을 명시적으로 나열하는 이유
-- `image/*` 와일드카드는 **image/svg+xml 을 함께 통과시킨다.** 와일드카드로는 뺄 수가
-- 없으므로 쓰지 않는다. 아래는 앱이 실제로 만들 수 있는 것만 적은 것이다:
--   jpeg/png  — 현재 운영 객체 전부(58 + 21건).
--   webp/gif  — 갤러리 선택 경로로 들어올 수 있다.
--   heic/heif — storage_service._normalizePhoto 가 **디코드 실패 시 원본을 그대로**
--               올린다(비-Safari 의 HEIC). 빼면 그 사용자만 조용히 업로드가 깨진다.
--   video     — quicktime(현재 4건, iOS) · mp4 · webm · 3gpp(안드로이드 갤러리).
--
-- ── 크기: 100MB
-- 앱의 동영상 상한과 같은 값이다. 사진은 이보다 훨씬 작지만 버킷 상한은 MIME 별로
-- 나눌 수 없어 가장 큰 쪽에 맞춘다. 무제한이 100MB 가 된 것이지 넉넉하다는 뜻은 아니다.
-- (참고: 현재 최대 객체는 14MB.)
update storage.buckets
   set file_size_limit    = 104857600,  -- 100MiB
       allowed_mime_types = array[
         'image/jpeg', 'image/png', 'image/webp', 'image/gif',
         'image/heic', 'image/heif',
         'video/mp4', 'video/quicktime', 'video/webm', 'video/3gpp'
       ]
 where id = 'media';
