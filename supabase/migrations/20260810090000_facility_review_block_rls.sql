-- 시설 후기·후기 댓글의 **기저 테이블 RLS** 에 차단 필터 추가.
--
-- 차단의 표시층은 피드 뷰가 담당해 왔고(v_facility_review_comment_feed 는
-- 20260807120000 에서 보강), 그것으로 앱 화면은 걸러진다. 그런데 두 테이블은
-- anon/authenticated 에 **직접 SELECT 권한**이 있다(실측 확인). 즉 PostgREST 로
-- `from('facility_reviews').select()` 를 그냥 부르면 뷰를 우회해 차단한 상대의
-- 후기·댓글이 그대로 읽힌다. 뷰만 고치면 표시만 가려질 뿐 접근은 열려 있다.
--
-- posts/comments 는 20260805090000 에서 이미 RLS 층에 같은 필터를 넣었다. 여기만
-- 빠져 있었다 — 같은 구멍의 마지막 두 곳이다.
--
-- 형태도 그쪽과 맞춘다:
--   · `(select app.blocked_ids())` — InitPlan 이라 쿼리당 1회 평가.
--   · anon 은 app.uid() 가 NULL → 빈 배열 → 전부 통과(비로그인 열람 불변).
--   · 관리자는 우회한다(신고 처리에 필요 — posts/comments 와 동일).
--   · app.blocked_ids() 는 **양방향**이다(내가 차단했거나 나를 차단했거나).

-- ── 시설 후기 ───────────────────────────────────────────────────────────
drop policy if exists fr_select on public.facility_reviews;
create policy fr_select on public.facility_reviews
  for select
  using (
    (
      visibility_status::text = 'visible'
      or user_id = (select app.uid())
    )
    and (
      (select app.is_admin())
      or not (user_id = any ((select app.blocked_ids())::uuid[]))
    )
  );

comment on policy fr_select on public.facility_reviews is
  '공개 후기 또는 본인 후기 — 단 차단 관계(양방향)인 상대의 것은 제외. 관리자는 우회.';

-- ── 시설 후기 댓글 ──────────────────────────────────────────────────────
drop policy if exists frc_select on public.facility_review_comments;
create policy frc_select on public.facility_review_comments
  for select
  using (
    (
      is_deleted = false
      or (select app.is_admin())
    )
    and (
      (select app.is_admin())
      or not (user_id = any ((select app.blocked_ids())::uuid[]))
    )
  );

comment on policy frc_select on public.facility_review_comments is
  '삭제되지 않은 댓글 — 단 차단 관계(양방향)인 상대의 것은 제외. 관리자는 우회.';
