-- 피드 가시성 버그 수정 (0021)
-- v_post_feed 가 소유자 권한으로 RLS 를 우회해, 삭제글(deleted_by_user)이 타 사용자
-- 피드에 그대로 노출되던 문제. posts_select 정책과 동일한 가시성 조건을 뷰에 명시.
--  · visible          → 전체 공개
--  · hidden_by_user   → 작성자 본인에게만
--  · 그 외(deleted 등) → 비공개(관리자 제외)
-- author_address(작성자 이동 경고용) 컬럼 유지. 운영 적용 완료(형상 기록).
create or replace view public.v_post_feed as
  select p.id, p.category, p.title, p.content, p.user_id,
         pr.nickname as author_nickname, pr.user_type as author_user_type,
         p.created_at, p.scheduled_at, p.display_address as location,
         p.heart_count, p.comment_count, p.view_count, p.progress_status,
         (exists (select 1 from public.post_hearts h
                   where h.post_id = p.id and h.user_id = app.uid())) as hearted,
         p.image_url, p.region_code, pr.address as author_address
    from public.posts p
    left join public.public_profiles pr on pr.id = p.user_id
   where p.visibility_status = 'visible'
      or (p.visibility_status = 'hidden_by_user' and p.user_id = app.uid())
      or app.is_admin();
