-- 차단은 접촉 차단이다 — 읽기도 막는다 (0032 §9.2 마지막 코드 항목).
--
-- 2026-08-03 에 차단이 쓰기·알림을 끊게 했다(0032 §2). 그런데 **읽기는 남아 있었다** —
-- `posts_select`·`comments_select` 에 차단 조건이 없어서, 차단한(혹은 당한) 상대의 글을
-- PostgREST 로 직접 조회하면 그대로 나왔다.
--
-- 앱 화면은 이미 가려져 있었다. 피드 뷰(`v_post_feed`·`v_comment_feed`)가 자체 WHERE 로
-- 걸러 왔기 때문이다. 즉 **가려진 것은 화면이지 데이터가 아니었다** — 이번에도 §0 의
-- '부분 적용' 이다. 방어가 있었고, 정상 사용 경로에만 걸려 있었다.
--
-- ── 왜 새 헬퍼를 만드는가
-- 조건 자체는 `app.is_blocked_pair(a, b)` 가 이미 정의한다. 하지만 그건 **두 사람**을
-- 받는 술어라 RLS 에 넣으면 두 번째 인자가 컬럼이 되어 **행마다** 호출된다. 방금
-- 20260804220000 에서 행별 호출을 걷어냈는데 여기서 다시 넣을 수는 없다.
--
-- 그래서 같은 조건의 **집합 형태**를 둔다: `app.blocked_ids()` 는 인자가 없으므로
-- `(select app.blocked_ids())` 로 감싸면 InitPlan 으로 **한 번만** 평가되고, 이후에는
-- 배열 대조만 남는다.
--
-- ⚠️ 둘은 같은 사실을 표현한다. 한쪽만 고치면 "쓰기는 막히는데 읽히거나" 그 반대가
--    된다 — 조건을 바꿀 일이 생기면 **반드시 같이** 고칠 것.
create or replace function app.blocked_ids()
returns uuid[]
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(array_agg(distinct other), '{}'::uuid[])
  from (
    select case when b.blocker_id = app.uid() then b.blocked_id else b.blocker_id end as other
    from public.user_blocks b
    where b.blocker_id = app.uid() or b.blocked_id = app.uid()
  ) s
$$;

-- ⚠️ **RLS 정책 표현식은 호출자 권한으로 평가된다.** 그래서 정책이 부르는 헬퍼는
-- 클라이언트 롤이 EXECUTE 할 수 있어야 한다 — 다른 app 헬퍼(`app.uid()`·`app.is_admin()`)가
-- 전부 그렇게 되어 있는 이유가 이것이다.
--
-- 처음에 습관대로 `revoke all … from public, anon, authenticated` 를 썼다가 **운영에서
-- posts·comments 조회가 통째로 42501 로 실패했다.** 정책이 못 부르는 함수를 참조하면
-- 행이 걸러지는 게 아니라 쿼리 자체가 죽는다. (SECURITY DEFINER 라 함수 안에서 하는
-- 일은 여전히 정의자 권한이므로, 실행 권한을 연다고 user_blocks 가 노출되지는 않는다.)
grant execute on function app.blocked_ids() to anon, authenticated, service_role;

-- `any(...)` 뒤에 `::uuid[]` 캐스트가 붙은 이유: 캐스트가 없으면 파서가
-- `= ANY (서브쿼리)` 형태로 읽어 `uuid = uuid[]` 를 비교하려 들고 그대로 실패한다.
-- 캐스트가 있으면 '배열 식' 으로 확정돼 의도한 `= ANY (배열)` 이 된다.
--
-- 비로그인(app.uid() = NULL)이면 빈 배열이 되고, `x = any('{}')` 는 false 라
-- 조건이 통과된다 — 익명에게는 차단 개념이 없다는 뜻이고 뷰의 기존 동작과 같다.
-- 관리자는 신고 처리를 위해 계속 전부 본다(뷰와 동일).

alter policy posts_select on public.posts
using (
  (
    ((visibility_status)::text = 'visible'::text)
    or (((visibility_status)::text = 'hidden_by_user'::text) and (user_id = (select app.uid())))
    or (select app.is_admin())
  )
  and (
    (select app.is_admin())
    or not (user_id = any ((select app.blocked_ids())::uuid[]))
  )
);

alter policy comments_select on public.comments
using (
  ((is_deleted = false) or (select app.is_admin()))
  and (
    (select app.is_admin())
    or not (user_id = any ((select app.blocked_ids())::uuid[]))
  )
);

-- 남는 것(의도적):
--   · public_profiles·post_hearts·pawings 는 여전히 공개다. 프로필 이름이 사라지면
--     이미 주고받은 대화·기록의 표시가 '알 수 없음' 으로 깨진다 — 차단은 새 접촉을
--     끊는 것이지 과거를 지우는 것이 아니다.
--   · SECURITY DEFINER RPC·뷰는 RLS 를 우회하므로 이 정책의 영향을 받지 않는다.
--     피드 뷰는 자체 차단 필터를 이미 갖고 있고, 관리자 RPC 는 봐야 하는 게 맞다.
