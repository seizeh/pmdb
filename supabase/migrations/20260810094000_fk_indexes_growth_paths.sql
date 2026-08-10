-- 부모 삭제가 자식 전수 스캔을 강제하는 FK 세 곳에 인덱스를 단다.
--
-- ── 왜 세 개만인가 ──────────────────────────────────────────────────────
--
-- 인덱스 없는 단일컬럼 FK 는 현재 23곳이다(auth/storage 스키마 포함). 전부 다는
-- 건 하지 않는다 — 인덱스는 쓰기마다 비용이 붙고, 지금 가장 큰 테이블이 111행이라
-- 대부분은 순차 스캔이 오히려 싸다. auth/storage 는 Supabase 관리 영역이라 손대지
-- 않는다.
--
-- 기준은 "행 수" 가 아니라 **부모 쪽 삭제가 구조적으로 반복되는가** 다. 인덱스
-- 없는 FK 가 실제로 아픈 순간은 조회가 아니라 부모 삭제·갱신이다. 참조 무결성을
-- 지키려고 자식 테이블을 통째로 훑기 때문이다.
--
-- ① chat_rooms.last_message_id       → chat_messages ON DELETE SET NULL
-- ② chat_room_members.last_read_message_id → chat_messages ON DELETE SET NULL
--
--   cleanup_retention 이 매일 chat_messages 를 대량 삭제한다(삭제 30일 경과분).
--   SET NULL 이라 삭제 행마다 두 테이블을 훑어 참조를 지워야 한다. 메시지가 쌓일수록
--   크론이 그대로 무거워지는 자리다.
--
-- ③ photo_verifications.pet_id       → pets (NO ACTION)
--
--   펫 삭제 때마다 photo_verifications 전수 확인이 필요하다. 사진 인증은 계속
--   쌓이는 테이블이라 삭제 한 번의 비용이 시간에 비례해 늘어난다.
--
-- 나머지(reviewed_by, invited_by, created_by 같은 관리자·초대자 참조)는 부모 삭제가
-- 반복되지 않아 제외한다. 필요해지면 그때 근거를 갖고 추가한다.

create index if not exists chat_rooms_last_message_id_idx
  on public.chat_rooms (last_message_id);

create index if not exists chat_room_members_last_read_message_id_idx
  on public.chat_room_members (last_read_message_id);

create index if not exists photo_verifications_pet_id_idx
  on public.photo_verifications (pet_id);
