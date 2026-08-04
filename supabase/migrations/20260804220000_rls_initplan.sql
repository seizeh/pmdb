-- RLS 정책의 무인자 헬퍼를 InitPlan 으로 — 행마다 부르던 것을 한 번만 (0032 §9.2).
--
-- `app.uid()` 는 가벼운 함수가 아니다. 매 호출마다 `request.jwt.claims` 를 세 번
-- jsonb 로 파싱하고 `public.users` 를 조회한다(상태·token_version·lite 확인).
-- 그런데 RLS 조건에 맨몸으로 놓이면 **읽는 행마다** 그게 다시 돈다 — 플래너가
-- STABLE 함수를 그 자리에서 자동으로 끌어올리지 않기 때문이다.
--
-- `(select app.uid())` 로 감싸면 스칼라 서브쿼리가 되어 InitPlan 으로 **한 번만**
-- 평가된다. 의미는 같다 — STABLE 은 한 문장 안에서 값이 변하지 않는다는 뜻이라
-- 끌어올리기가 정의상 안전하다.
--
-- ── 실측 (테스트 프로젝트, 5만 행, 같은 쿼리)
--   맨몸  : Seq Scan → Filter: (user_id = app.uid())      실행 1250.2 ms
--   감쌈  : InitPlan 1 → Filter: (user_id = (InitPlan 1)) 실행    6.2 ms
--   200배. 운영 데이터가 아직 작아 지금 체감은 없지만, 이건 **행 수에 비례해
--   커지는 비용**이라 데이터가 쌓인 뒤에 고치면 이미 늦다.
--
-- ── 무엇을 감쌌고 무엇은 못 감쌌나
-- 감싼 것: 인자 없는 헬퍼 `app.uid()` · `app.is_admin()` · `app.uid_lite()`.
--   행과 무관하므로 한 번 계산하면 된다.
-- 못 감싼 것: `app.is_pet_guardian(pet_id, …)` · `app.is_post_manager(post_id)` ·
--   `app.is_room_member(room_id)` 처럼 **컬럼을 인자로 받는** 헬퍼(15개 정책).
--   행마다 값이 달라 끌어올릴 수 없다. 이들 내부에서 다시 app.uid() 를 부르므로
--   그 경로는 여전히 행별 비용이 있다 — 병목이 되면 헬퍼 시그니처를 바꿔야 하고,
--   그건 별개 작업이다.
--
-- Supabase 성능 린터(0003_auth_rls_initplan)는 이 문제를 잡지 못한다. 그 린트는
-- `auth.uid()` 를 찾는데 우리는 커스텀 `app.uid()` 를 쓴다.
--
-- 정책을 drop/create 하지 않고 `alter policy` 로 조건만 바꾼다 — 정책이 잠깐이라도
-- 사라지는 창을 만들지 않는다.

alter policy admin_logs_select on public.admin_logs using ((select app.is_admin()));
alter policy applications_insert on public.applications with check ((applicant_id = (select app.uid())));
alter policy applications_select on public.applications using (((applicant_id = (select app.uid())) OR app.is_post_manager(post_id)));
alter policy applications_update on public.applications using (((applicant_id = (select app.uid())) OR app.is_post_manager(post_id)));
alter policy appointments_select on public.appointments using (((post_owner_id = (select app.uid())) OR (applicant_id = (select app.uid())) OR (select app.is_admin())));
alter policy appointments_update on public.appointments using (((post_owner_id = (select app.uid())) OR (applicant_id = (select app.uid())) OR (select app.is_admin()))) with check (((post_owner_id = (select app.uid())) OR (applicant_id = (select app.uid())) OR (select app.is_admin())));
alter policy business_match_rules_admin_select on public.business_match_rules using ((select app.is_admin()));
alter policy business_profiles_select_own on public.business_profiles using ((user_id = (select app.uid())));
alter policy chat_message_deletions_insert on public.chat_message_deletions with check ((user_id = (select app.uid())));
alter policy chat_message_deletions_select on public.chat_message_deletions using ((user_id = (select app.uid())));
alter policy chat_messages_insert on public.chat_messages with check (((sender_id = (select app.uid())) AND app.is_room_member(room_id)));
alter policy chat_messages_select on public.chat_messages using ((app.is_room_member(room_id) OR (select app.is_admin())));
alter policy chat_messages_update on public.chat_messages using ((select app.is_admin()));
alter policy chat_room_members_insert on public.chat_room_members with check (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy chat_room_members_select on public.chat_room_members using (((user_id = (select app.uid())) OR app.is_room_member(room_id) OR (select app.is_admin())));
alter policy chat_room_members_update on public.chat_room_members using ((user_id = (select app.uid()))) with check ((user_id = (select app.uid())));
alter policy chat_rooms_insert on public.chat_rooms with check (((select app.uid()) IS NOT NULL));
alter policy chat_rooms_select on public.chat_rooms using ((app.is_room_member(id) OR (select app.is_admin())));
alter policy chat_rooms_update on public.chat_rooms using ((select app.is_admin()));
alter policy comments_insert on public.comments with check ((user_id = (select app.uid())));
alter policy comments_select on public.comments using (((is_deleted = false) OR (select app.is_admin())));
alter policy comments_update on public.comments using (((user_id = (select app.uid())) OR (select app.is_admin()))) with check (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy device_tokens_all on public.device_tokens using ((user_id = (select app.uid()))) with check ((user_id = (select app.uid())));
alter policy facility_cache_delete on public.facility_cache using ((select app.is_admin()));
alter policy facility_cache_insert on public.facility_cache with check ((select app.is_admin()));
alter policy facility_cache_update on public.facility_cache using ((select app.is_admin())) with check ((select app.is_admin()));
alter policy frc_insert on public.facility_review_comments with check ((user_id = (select app.uid())));
alter policy frc_select on public.facility_review_comments using (((is_deleted = false) OR (select app.is_admin())));
alter policy frc_update on public.facility_review_comments using (((user_id = (select app.uid())) OR (select app.is_admin()))) with check (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy fr_select on public.facility_reviews using ((((visibility_status)::text = 'visible'::text) OR (user_id = (select app.uid()))));
alter policy location_verifications_insert on public.location_verifications with check ((user_id = (select app.uid())));
alter policy location_verifications_select on public.location_verifications using (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy notification_preferences_all on public.notification_preferences using ((user_id = (select app.uid()))) with check ((user_id = (select app.uid())));
alter policy notifications_delete on public.notifications using (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy notifications_insert on public.notifications with check ((select app.is_admin()));
alter policy notifications_select on public.notifications using (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy notifications_update on public.notifications using (((user_id = (select app.uid())) OR (select app.is_admin()))) with check (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy pawings_delete on public.pawings using ((follower_id = (select app.uid())));
alter policy pawings_insert on public.pawings with check ((follower_id = (select app.uid())));
alter policy pgi_insert on public.pet_guardian_invites with check (((inviter_id = (select app.uid())) AND ((((kind)::text = 'invite'::text) AND app.is_pet_guardian(pet_id, 'owner'::text)) OR ((kind)::text = 'request'::text))));
alter policy pgi_select on public.pet_guardian_invites using (((inviter_id = (select app.uid())) OR (invitee_user_id = (select app.uid())) OR app.is_pet_guardian(pet_id, 'owner'::text) OR (select app.is_admin())));
alter policy pgi_update on public.pet_guardian_invites using (((select app.is_admin()) OR (((kind)::text = 'invite'::text) AND (invitee_user_id = (select app.uid()))) OR (((kind)::text = 'request'::text) AND app.is_pet_guardian(pet_id, 'owner'::text))));
alter policy pet_guardians_delete on public.pet_guardians using ((app.is_pet_guardian(pet_id, 'owner'::text) OR (select app.is_admin())));
alter policy pet_guardians_insert on public.pet_guardians with check ((app.is_pet_guardian(pet_id, 'owner'::text) OR (select app.is_admin())));
alter policy pet_guardians_select on public.pet_guardians using ((app.is_pet_guardian(pet_id) OR (select app.is_admin())));
alter policy pet_guardians_update on public.pet_guardians using ((app.is_pet_guardian(pet_id, 'owner'::text) OR (select app.is_admin()))) with check ((app.is_pet_guardian(pet_id, 'owner'::text) OR (select app.is_admin())));
alter policy pif_select_guardian on public.pet_identity_frames using (((EXISTS ( SELECT 1
   FROM pet_guardians g
  WHERE ((g.pet_id = pet_identity_frames.pet_id) AND (g.user_id = (select app.uid()))))) OR (select app.is_admin())));
alter policy pets_insert on public.pets with check ((primary_guardian_id = (select app.uid())));
alter policy pets_select on public.pets using ((((pet_status)::text <> 'deleted'::text) OR app.is_pet_guardian(id) OR (select app.is_admin())));
alter policy pets_update on public.pets using ((app.is_pet_guardian(id, 'owner'::text) OR (select app.is_admin()))) with check ((app.is_pet_guardian(id, 'owner'::text) OR (select app.is_admin())));
alter policy post_hearts_delete on public.post_hearts using ((user_id = (select app.uid())));
alter policy post_hearts_insert on public.post_hearts with check ((user_id = (select app.uid())));
alter policy post_pets_delete on public.post_pets using (((EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_pets.post_id) AND (p.user_id = (select app.uid()))))) OR (select app.is_admin())));
alter policy post_pets_insert on public.post_pets with check ((EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_pets.post_id) AND (p.user_id = (select app.uid()))))));
alter policy post_pets_select on public.post_pets using ((EXISTS ( SELECT 1
   FROM posts p
  WHERE ((p.id = post_pets.post_id) AND (((p.visibility_status)::text = 'visible'::text) OR (p.user_id = (select app.uid())) OR (select app.is_admin()))))));
alter policy post_views_insert on public.post_views with check ((user_id = (select app.uid())));
alter policy post_views_select on public.post_views using ((select app.is_admin()));
alter policy posts_delete on public.posts using ((select app.is_admin()));
alter policy posts_insert on public.posts with check ((user_id = (select app.uid())));
alter policy posts_select on public.posts using ((((visibility_status)::text = 'visible'::text) OR (((visibility_status)::text = 'hidden_by_user'::text) AND (user_id = (select app.uid()))) OR (select app.is_admin())));
alter policy posts_update on public.posts using (((user_id = (select app.uid())) OR (select app.is_admin()))) with check (((user_id = (select app.uid())) OR (select app.is_admin())));
alter policy reports_insert on public.reports with check ((reporter_id = (select app.uid())));
alter policy reports_select on public.reports using (((reporter_id = (select app.uid())) OR (select app.is_admin())));
alter policy reports_update on public.reports using ((select app.is_admin())) with check ((select app.is_admin()));
alter policy reviews_insert on public.reviews with check ((reviewer_id = (select app.uid())));
alter policy user_blocks_delete on public.user_blocks using ((blocker_id = (select app.uid())));
alter policy user_blocks_insert on public.user_blocks with check ((blocker_id = (select app.uid())));
alter policy user_blocks_select on public.user_blocks using ((blocker_id = (select app.uid())));
alter policy users_select on public.users using ((((status)::text <> 'suspended'::text) OR (id = (select app.uid())) OR (select app.is_admin())));
alter policy users_update on public.users using (((id = (select app.uid())) OR (select app.is_admin()))) with check (((id = (select app.uid())) OR (select app.is_admin())));
alter policy "business docs admin select" on storage.objects using (((bucket_id = 'business-docs'::text) AND (select app.is_admin())));
alter policy "business docs owner insert" on storage.objects with check (((bucket_id = 'business-docs'::text) AND ((storage.foldername(name))[1] = ((select app.uid()))::text)));
alter policy "business docs owner select" on storage.objects using (((bucket_id = 'business-docs'::text) AND ((storage.foldername(name))[1] = ((select app.uid()))::text)));
alter policy "media lite review insert" on storage.objects with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = ((select app.uid_lite()))::text) AND ((storage.foldername(name))[2] = 'facility_review'::text)));
alter policy "media owner delete" on storage.objects using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = ((select app.uid()))::text)));
alter policy "media owner insert" on storage.objects with check (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = ((select app.uid()))::text)));
alter policy "media owner update" on storage.objects using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = ((select app.uid()))::text)));
