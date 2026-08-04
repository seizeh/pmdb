-- 인덱스 없는 외래키 중 **실제 조회 경로가 있는 것만** 7개 (0032 §9.2).
--
-- Supabase 성능 어드바이저는 인덱스 없는 FK 를 23건 신고한다. 전부 만들지는 않는다 —
-- 인덱스는 공짜가 아니라 쓰기마다 갱신 비용과 저장 공간을 먹는다. 한 번도 조건으로
-- 쓰이지 않는 컬럼(예: `reports.reviewed_by`, `business_licenses.reviewed_by`,
-- `refresh_tokens.replaced_by`)에 인덱스를 다는 건 비용만 늘리는 일이다.
--
-- 기준은 **가리킬 수 있는 질의 경로가 있는가**. 아래 7개는 각각 근거가 있다.
-- 나머지 16건은 지금 조건으로 쓰이지 않아 두었고, 쓰이기 시작하면 그때 단다.
--
-- 지금 다는 이유: 지금은 테이블이 작아 어느 쪽이든 티가 안 난다. 하지만 여기 적은
-- 경로들은 **행 수에 비례해 나빠지는 것**들이라, 느껴질 때는 이미 늦다.
-- 반대로 인덱스 생성 락도 지금이 가장 싸다.

-- ① 간이 회원 전화번호 파기(cleanup_retention, 매일)가 lite 사용자마다
--    `not exists (select 1 from facility_reviews r where r.user_id = u.id)` 를 돈다.
--    인덱스가 없으면 lite 사용자 수 × facility_reviews 전체 스캔이다.
--    RLS `fr_select` 의 `user_id = app.uid()` 도 같은 인덱스를 쓴다.
create index facility_reviews_user_idx on public.facility_reviews (user_id);

-- ② 프로필의 '내가 쓴 평가' + trg_reviews_validate 의 당사자 확인.
--    `reviews_uq (appointment_id, reviewer_id)` 가 있지만 reviewer_id 가 **두 번째**
--    컬럼이라 reviewer_id 단독 조회에는 쓰이지 못한다.
create index reviews_reviewer_idx on public.reviews (reviewer_id);

-- ③ 알림 회수 트리거 3종(좋아요 취소·팔로우 해제·후기 숨김)이 전부
--    `actor_user_id = …` 로 지운다. notifications 는 가장 빨리 자라는 테이블이다.
create index notifications_actor_idx on public.notifications (actor_user_id);

-- ④ 안읽음 정산(trg_chat_members_read)이 구간 내 '상대가 보낸' 메시지를 세고,
--    차단 트리거도 sender_id 로 본다. chat_messages 도 고성장 테이블이다.
create index chat_messages_sender_idx on public.chat_messages (sender_id);

-- ⑤⑥ 사진 검증 보존 정리(cleanup_retention, 매일)가 photo_verifications 행마다
--    `not exists (… from pets where ai_ref_verification_id = pv.id)` 와
--    `not exists (… from posts where photo_verification_id = pv.id)` 를 돈다.
--    둘 다 상관 서브쿼리라 인덱스가 없으면 행마다 전체 스캔이다.
create index pets_ai_ref_idx on public.pets (ai_ref_verification_id);
create index posts_photo_verification_idx on public.posts (photo_verification_id);

-- ⑦ 시설 후기가 달릴 때마다 tg_notify_facility_review 가
--    `matched_facility_id = any(facility_sibling_ids(...))` 로 업체를 찾고,
--    share_view_load 의 lateral 도 같은 조건을 쓴다.
create index business_profiles_matched_facility_idx
  on public.business_profiles (matched_facility_id);
