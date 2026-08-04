// media 버킷 업로드에 쓸 수 있는 MIME — **버킷 설정과 같은 목록을 앞당겨 본다.**
//
// 진짜 관문은 버킷이다(20260804200000: allowed_mime_types + file_size_limit).
// 여기서 한 번 더 보는 이유는 보안이 아니라 **오탐 알람과 응답 품질** 때문이다:
// 검사 없이 넘기면 클라이언트가 보낸 이상한 mimeType 이 스토리지에서 415 로 튕기고,
// 그건 함수 안에서 "업로드 실패" 로 보여 internal_error(500) + 관리자 알람이 된다.
// 잘못된 입력은 400 으로 돌려주는 게 맞고, 알람은 진짜 고장에만 울려야 한다.
//
// ⚠️ 버킷 목록이 바뀌면 여기도 같이 고칠 것. 이쪽이 더 좁은 건 괜찮지만(이미지 전용
//    경로라 영상 타입을 뺐다) **더 넓으면 안 된다** — 통과시켜 놓고 스토리지에서
//    튕기는, 지금 고치려는 그 상태로 되돌아간다.
const IMAGE_MIMES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "image/heif",
]);

/// 이미지 업로드용 MIME 검증. 허용되면 그대로, 아니면 null.
export function imageMime(raw: string | undefined): string | null {
  const m = (raw ?? "").trim().toLowerCase();
  if (!m) return null;
  return IMAGE_MIMES.has(m) ? m : null;
}
