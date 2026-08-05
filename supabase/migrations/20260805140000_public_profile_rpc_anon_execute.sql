-- 게스트(비로그인)도 공개 프로필을 온전히 보게 — definer RPC 2개에 anon EXECUTE.
--
-- 배경: 게스트가 게시글 작성자 프로필을 열면 public_user_pets 가 42501 로 거부돼
-- 펫 목록이 조용히 빈 배열로 떨어졌다(app.client_errors 2026-08-05, iOS 게스트).
-- pet_guardians_of 는 같은 패턴의 잠재 결함(공개 펫 프로필의 보호자 목록).
--
-- 두 함수 모두 호출자(app.uid()) 의존이 없는 공개 데이터 순수 조회라 anon 에
-- 안전하다. 반면 feed_region_codes(게스트 호출을 앱이 가드)·post_edit_locked·
-- create_post_share_link(로그인 전제)는 의도적으로 열지 않는다 — 과잉 GRANT 는
-- definer 함수의 무인증 노출이다(definer-view-write-grants 교훈과 동일 원칙).

grant execute on function public.public_user_pets(uuid) to anon;
grant execute on function public.pet_guardians_of(uuid) to anon;
