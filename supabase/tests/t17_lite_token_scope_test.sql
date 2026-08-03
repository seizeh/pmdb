-- 간이 후기 토큰의 권한 범위 + 게이트 카운터의 쓰기 경로 잠금 (20260803180000~182000).
--
-- 이 세 가지는 전부 "방어가 있는데 실제로는 안 막던" 것들이라, 다음에 누가
-- 되돌려도 조용히 통과하지 않도록 못을 박아 둔다.
--   1) signup-lite 토큰(lite=true)은 app.uid() 를 통과하면 안 된다 — 통과하면
--      정식 회원 계정에 대한 완전 세션이 된다.
--   2) 그러면서도 app.uid_lite() 는 통과해야 한다 — 안 그러면 후기를 못 쓴다.
--   3) post_pets 직접 쓰기가 열리면 pets.verify_post_count 를 부풀려
--      사진 인증 게이트(1·4·10번째, t16)를 건너뛸 수 있다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(8);

-- ── 1) 정상 토큰은 그대로 통과해야 한다(회귀 방지의 대조군) ────────────────
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text,
  true);

select is(app.uid(), (select id from seed where k='owner')::uuid,
  '정상 토큰: app.uid() 가 사용자를 돌려준다');
select is(app.uid_lite(), (select id from seed where k='owner')::uuid,
  '정상 토큰: app.uid_lite() 도 사용자를 돌려준다');

-- ── 2) lite 클레임 토큰 — 같은 계정, 같은 tv, 클레임만 추가 ────────────────
-- 여기가 핵심이다. 계정은 status='active' 인 정식 회원 그대로이므로, 계정 상태로
-- 판정하던 예전 코드는 이 토큰을 완전 세션으로 받아들였다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0, 'lite', true)::text,
  true);

select is(app.uid(), null,
  'lite 토큰: app.uid() 는 NULL — 채팅·게시글·펫 등 일반 경로 전부 차단');
select is(app.uid_lite(), (select id from seed where k='owner')::uuid,
  'lite 토큰: app.uid_lite() 는 통과 — 후기 작성 경로는 살아 있다');
select is(app.is_admin(), false,
  'lite 토큰: is_admin() 도 false — app.uid() 를 경유하므로 함께 막힌다');

-- 'lite' 가 문자열 'true' 가 아닌 값이면 제한이 걸리지 않아야 한다(정상 토큰 취급).
-- ::boolean 캐스팅으로 짰다면 여기서 캐스트 오류가 나 RLS 가 통째로 깨진다 —
-- 거부가 아니라 쿼리 실패가 되므로 텍스트 비교로 짠 이유를 고정한다.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0, 'lite', 'nonsense')::text,
  true);
select is(app.uid(), (select id from seed where k='owner')::uuid,
  'lite 클레임이 예상 밖 문자열이어도 오류 없이 정상 토큰으로 처리된다');

-- ── 3) post_pets 직접 쓰기 권한이 없어야 한다 ─────────────────────────────
-- 있으면 (post_id, pet_id) 삽입 → 삭제 반복으로 verify_post_count 를 올려
-- 사진 인증 게이트를 통째로 넘길 수 있다. 트리거는 INSERT 에서만 +1 하고
-- DELETE 분기가 없는데(의도된 것), 그 전제는 "RPC 밖에서 INSERT 할 수 없다" 이다.
select is(
  has_table_privilege('authenticated', 'public.post_pets', 'INSERT'), false,
  'authenticated 는 post_pets 에 INSERT 할 수 없다(게이트 카운터 우회 차단)');
select is(
  has_table_privilege('authenticated', 'public.post_pets', 'DELETE'), false,
  'authenticated 는 post_pets 를 DELETE 할 수 없다(재삽입으로 카운터 반복 증가 차단)');

select * from finish();
rollback;
