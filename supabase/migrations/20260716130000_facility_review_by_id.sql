-- 후기 단건 조회 RPC — 후기 댓글 알림(review_comment) 딥링크용.
-- facility_reviews_of 와 동일한 행 모양(작성자 닉네임·is_mine·visit_no).
-- visit_no 는 목록과 동일하게 형제 시설(facility_sibling_ids) 범위에서 계산.

create or replace function public.facility_review_by_id(p_review uuid)
returns table(
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamp with time zone, is_mine boolean, visit_no integer
)
language sql stable security definer set search_path to ''
as $function$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.facility_id = any(public.facility_sibling_ids(
               (select facility_id from public.facility_reviews where id = p_review)))
         and fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
   where r.id = p_review;
$function$;

grant execute on function public.facility_review_by_id(uuid) to anon, authenticated;
