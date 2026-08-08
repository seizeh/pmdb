-- 시설 후기 댓글 피드에 차단 필터 추가 — 차단 표시층의 마지막 누락 뷰.
--
-- 차단의 표시층은 피드 뷰의 WHERE 가 담당한다(v_post_feed·v_comment_feed·v_chat_rooms).
-- 그런데 7/16 신설된 v_facility_review_comment_feed 에는 **처음부터 이 필터가 없었고**
-- (20260716120000 원본 확인 — 재정의 회귀가 아니라 신설 시점 누락), 0032 §2 차단
-- 일원화 때도 대상에서 빠졌다. 차단한(당한) 상대의 시설 후기 댓글이 그대로 보였다.
-- definer 뷰라 기저 테이블 RLS(frc_select — 차단 조건 없음)로도 걸리지 않는다.
-- 2026-08-07 운영 실측: 뷰 본문·frc_select·public_profiles 모두 차단 조건 없음.
-- (docs/supabase-db.md §6.7 이 "차단 필터 포함" 으로 기술한 것은 오기였다 — 같이 정정)
--
-- 필터는 20260805090000 이 posts/comments SELECT RLS 에 쓴 것과 같은 **집합 형태**를
-- 쓴다 — `(select app.blocked_ids())` 는 InitPlan 으로 쿼리당 한 번만 평가된다.
-- anon 은 app.uid() 가 NULL 이라 빈 배열 → 전부 통과(비로그인 열람 불변).
-- create or replace 라 기존 GRANT(anon/authenticated SELECT)는 유지된다.
create or replace view public.v_facility_review_comment_feed as
 select c.id,
    c.review_id,
    c.user_id,
    c.content,
    c.created_at,
    (case when c.authored_as = 'business'
          then coalesce(bp.business_name, '업체')
          else pr.nickname::text end)::character varying(50) as author_nickname,
    c.authored_as
   from public.facility_review_comments c
     left join public.public_profiles pr on pr.id = c.user_id
     left join public.business_profiles bp
       on bp.user_id = c.user_id and bp.status = 'approved'
  where c.is_deleted = false
    and not (c.user_id = any ((select app.blocked_ids())::uuid[]));
