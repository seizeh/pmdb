-- v_post_feed 에 작성자 현재 주소(author_address) 노출 (0021). 운영 적용 완료(형상 기록).
-- 글의 동(display_address=작성 당시)과 작성자 현재 동을 비교해
-- "작성자가 현재 다른 지역에 있어요" 경고 표시용. 저감도(동 단위, public_profiles.address).
create or replace view public.v_post_feed as
  select p.id, p.category, p.title, p.content, p.user_id,
         pr.nickname as author_nickname, pr.user_type as author_user_type,
         p.created_at, p.scheduled_at, p.display_address as location,
         p.heart_count, p.comment_count, p.view_count, p.progress_status,
         (exists (select 1 from public.post_hearts h
                   where h.post_id = p.id and h.user_id = app.uid())) as hearted,
         p.image_url, p.region_code, pr.address as author_address
    from public.posts p
    left join public.public_profiles pr on pr.id = p.user_id;
