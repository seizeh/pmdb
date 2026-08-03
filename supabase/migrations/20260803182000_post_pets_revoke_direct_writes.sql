-- post_pets 직접 쓰기 권한 회수 — 사진 인증 게이트(1·4·10번째)의 우회로를 막는다.
--
-- ── 무엇이 문제였나 ────────────────────────────────────────────────────────
-- 게이트 판정은 값이 **정확히** 그 셋일 때만 참이다:
--
--   app.needs_photo_gate(n) := n in (0, 3, 9)
--
-- 그리고 pets.verify_post_count 는 app.tg_post_pets_bump_verify_count() 가
-- post_pets INSERT 마다 +1 한다. DELETE 분기가 없는 건 **의도된 것**이다
-- (20260728103000 — "지웠다 다시 쓰는 방식으로 게이트를 피하지 못하게").
--
-- 그런데 과대계상 방향이 고려되지 않았다. authenticated 에 post_pets
-- INSERT/DELETE 권한이 있고, 정책은 둘 다 조건이 "내가 쓴 글이면 OK" 뿐이며,
-- post_pets_uq 는 DELETE 하면 풀려 재삽입이 된다.
--
--   자기 소유의 기존 walk_together 글에 (post_id, pet_id) 삽입 → 삭제 1회
--   → verify_post_count 3 → 4
--   → 다음 글에서 create_post_verified 의 v_exempt 가 참
--   → app.photo_trusted='true' → tg_posts_check_write 가 사진 토큰 검사를 건너뜀
--
-- 9(10번째)도 같은 방법으로 넘긴다. REST 로 두 번 호출하면 끝이다.
--
-- ── 왜 DELETE 에서 감소시키지 않는가 ──────────────────────────────────────
-- 그건 원래 막으려던 우회(지웠다 다시 쓰기)를 되살린다. 실제 결함은 카운터의
-- 증감 규칙이 아니라 **카운터를 RPC 밖에서 움직일 수 있다는 것**이다.
-- 20260728103000 의 주석은 "RPC 밖(직접 INSERT) 경로도 새지 않도록 트리거로" 라고
-- 적었는데, 그 직접 경로가 카운터를 **올리는** 데도 쓰인다는 걸 놓쳤다.
-- 방어를 트리거로 옮기면서 정작 트리거를 발화시키는 문을 잠그지 않았다.
--
-- ── 조치 ──────────────────────────────────────────────────────────────────
-- post_pets 는 create_post_verified(SECURITY DEFINER)가 쓴다. 클라이언트가 직접
-- 쓸 이유가 없다 — 앱도 조회만 한다(community_repository.dart 의 .from('post_pets')
-- 는 select 하나뿐). 쓰기 권한을 회수한다.
--
-- RLS 정책(post_pets_insert / post_pets_delete)은 **남겨 둔다.** 지금은 GRANT 가
-- 없어 도달하지 않지만, 나중에 누가 권한을 되돌리더라도 최소한 남의 글은 못 건드린다.
revoke insert, update, delete, truncate on table public.post_pets from authenticated;
revoke insert, update, delete, truncate on table public.post_pets from anon;

comment on table public.post_pets is
  '게시글↔펫 연결. 쓰기는 create_post_verified(definer) 전용 — 직접 INSERT 는 '
  'pets.verify_post_count 를 부풀려 사진 인증 게이트를 우회시킨다(20260803182000).';
