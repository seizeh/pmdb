-- 개인↔업체 정체성 연결 차단 (0025 후속 — "어떤 사용자가 어떤 업체를 운영하는지
-- 모르게"). 업체 모드로 작성한 게시글이 피드에서 개인 닉네임으로 표시되어
-- 상호↔닉네임 연결이 노출되던 누수를 서버에서 봉인:
--   - authored_as='business' 글: 작성자 = 상호(승인 업체), 동네(author_address) 비노출
--   - authored_as 를 뷰에 노출해 앱이 작성자 탭 시 얼굴(개인/업체)을 맥락대로 연다
-- author_nickname 컬럼 타입(varchar) 유지 위해 명시 캐스트.
create or replace view public.v_post_feed as
 select p.id,
    p.category,
    p.title,
    p.content,
    p.user_id,
    (case when p.authored_as = 'business'
          then coalesce(bp.business_name, '업체')
          else pr.nickname::text end)::character varying(50) as author_nickname,
    pr.user_type as author_user_type,
    p.created_at,
    p.scheduled_at,
    p.display_address as location,
    p.heart_count,
    p.comment_count,
    p.view_count,
    p.progress_status,
    (exists ( select 1
           from post_hearts h
          where h.post_id = p.id and h.user_id = app.uid())) as hearted,
    p.image_url,
    p.region_code,
    (case when p.authored_as = 'business' then null else pr.address end)::character varying(100) as author_address,
    p.edited_at,
    p.authored_as
   from posts p
     left join public_profiles pr on pr.id = p.user_id
     left join business_profiles bp on bp.user_id = p.user_id and bp.status = 'approved'
  where p.visibility_status::text = 'visible'::text
     or p.visibility_status::text = 'hidden_by_user'::text and p.user_id = app.uid()
     or app.is_admin();
