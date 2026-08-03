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
--
-- ACL 을 직접 읽는다. has_table_privilege() 로 쓰면 **환경마다 답이 갈린다** —
-- 그 함수는 롤 상속과 PUBLIC 부여까지 합산한 '실효 권한'을 돌려주므로, CI 컨테이너처럼
-- 롤 구성이 운영과 다른 곳에서는 GRANT 를 회수해도 true 가 나온다(실제로 그렇게 나왔다).
-- 우리가 고정하려는 건 실효 권한이 아니라 **이 테이블의 ACL 에 쓰기 항목이 없다** 는
-- 사실이므로, 합산되지 않는 relacl 을 본다.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join lateral aclexplode(c.relacl) a
     join pg_roles r on r.oid = a.grantee
    where n.nspname = 'public' and c.relname = 'post_pets'
      and r.rolname = 'authenticated'
      and a.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
  0,
  'post_pets ACL 에 authenticated 쓰기 권한이 없다(게이트 카운터 우회 차단)');

-- 조회는 남아 있어야 한다 — 앱이 글 상세에서 연결된 펫을 읽는다.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join lateral aclexplode(c.relacl) a
     join pg_roles r on r.oid = a.grantee
    where n.nspname = 'public' and c.relname = 'post_pets'
      and r.rolname = 'authenticated'
      and a.privilege_type = 'SELECT'),
  1,
  'post_pets SELECT 은 유지 — 회수가 조회까지 끊지 않았다');

select * from finish();
rollback;
