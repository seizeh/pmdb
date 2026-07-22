-- ============================================================================
-- share_view_load 에 인증 업체 대표 사진·영업시간 추가 (0028 §3 콜드스타트 완화)
--
-- 후기 0개 매장의 미리보기가 명함 수준으로 빈약한 문제: 인증 업체는 이미
-- 대표 사진(photo_url, 지도 상세 히어로와 동일)과 영업시간을 갖고 있으므로
-- 공유 뷰어도 같은 데이터로 채운다. 매칭은 facilities_within 과 동일하게
-- 형제 시설(facility_sibling_ids) 범위의 승인 업체 기준.
-- jsonb 반환이라 시그니처 불변 — create or replace 로 안전 교체.
-- ============================================================================

create or replace function public.share_view_load(p_token varchar)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_link app.share_links%rowtype;
  v_out  jsonb;
begin
  select * into v_link from app.share_links where token = p_token;
  if not found or v_link.revoked_at is not null then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_link.expires_at < now() then
    return jsonb_build_object('status', 'expired');
  end if;

  update app.share_links set view_count = view_count + 1 where token = p_token;
  insert into app.funnel_events (event, token) values ('share_view', p_token);

  if v_link.kind = 'facility_preview' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'facility', jsonb_build_object(
        'name', f.name, 'category', f.category, 'address', f.address,
        'phone', f.phone, 'is_open', f.is_open,
        'avg_rating', f.avg_rating, 'review_count', f.review_count,
        'photo_url', bp.photo_url,
        'photo_align_y', coalesce(bp.photo_align_y, 0),
        'business_hours', bp.business_hours),
      'reviews', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'rating', r.rating, 'content', r.content,
                 'has_incentive', r.has_incentive)
                 order by r.created_at desc)
        from (select rating, content, has_incentive, created_at
              from public.facility_reviews
              where facility_id = f.id and visibility_status = 'visible'
              order by created_at desc limit 3) r), '[]'::jsonb))
    into v_out
    from public.facilities f
    left join lateral (
      select b.photo_url, b.photo_align_y, b.business_hours
        from public.business_profiles b
       where b.status = 'approved'
         and b.matched_facility_id = any(public.facility_sibling_ids(f.id))
       order by b.reviewed_at nulls last
       limit 1
    ) bp on true
    where f.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;
