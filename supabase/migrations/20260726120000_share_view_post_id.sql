-- ============================================================================
-- 공유 뷰어 → 웹앱 연결: post 분기에 게시글 id 노출
--
--  · 배경: 공유 링크(go.pawmate.kr/s)에 "웹에서 계속 보기" CTA 를 붙여 웹앱
--    (app.pawmate.kr/p/<postId>)으로 잇는다. 서버 렌더링 미리보기·OG 태그·
--    퍼널 계측은 그대로 두고 동선만 추가한다(pmdart docs/web-port.md 결정 6).
--  · share_view_load 는 service_role 전용이라 웹앱(anon)이 토큰을 못 읽는다.
--    새 anon RPC 를 파는 대신 **이미 서버가 아는 post id 를 응답에 싣는다** —
--    Edge Function 이 그 id 로 CTA 주소를 만든다. 권한 변경 없음.
--  · 노출 확대가 아니다: 게시글 자체는 v_post_feed 로 이미 anon 열람 가능하고
--    (비로그인 둘러보기), id 는 그 뷰의 키다. 좌표·전화·지역코드는 여전히 미노출.
--
--  ⚠️ 이 함수는 여러 마이그레이션이 나눠 고쳐 왔다(hero·photo_first·
--     owner_verified·review_photos·post_share). 아래 정의는 **적용 시점의
--     프로덕션 현재 정의**(pg_get_functiondef)에 'id' 한 줄만 더한 것이다 —
--     과거 마이그레이션을 합성하지 말 것(병렬 변경 유실).
--
--  적용 후: ./scripts/dump_schema.sh 로 스키마 스냅샷 갱신 + 커밋.
-- ============================================================================

create or replace function public.share_view_load(p_token character varying)
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
        'business_hours', bp.business_hours,
        'owner_verified', coalesce(bp.verified, false)),
      'reviews', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'rating', r.rating, 'content', r.content,
                 'has_incentive', r.has_incentive,
                 'photo_urls', r.photos,
                 'videos', r.videos)
                 order by r.has_media desc, r.created_at desc)
        from (select rating, content, has_incentive, created_at, videos,
                     coalesce(array_length(photo_urls, 1), 0) > 0
                       or jsonb_array_length(videos) > 0 as has_media,
                     (select coalesce(jsonb_agg(u), '[]'::jsonb)
                        from unnest(photo_urls[1:2]) u) as photos
              from public.facility_reviews
              where facility_id = f.id and visibility_status = 'visible'
              order by coalesce(array_length(photo_urls, 1), 0) > 0
                         or jsonb_array_length(videos) > 0 desc,
                       created_at desc
              limit 3) r), '[]'::jsonb))
    into v_out
    from public.facilities f
    left join lateral (
      select true as verified, b.photo_url, b.photo_align_y, b.business_hours
        from public.business_profiles b
       where b.status = 'approved'
         and b.matched_facility_id = any(public.facility_sibling_ids(f.id))
       order by b.reviewed_at nulls last
       limit 1
    ) bp on true
    where f.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  if v_link.kind = 'care_report' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'report', jsonb_build_object(
        'pet_label', r.pet_label, 'photos', r.photos, 'note', r.note,
        'kind', r.kind, 'body', r.body, 'created_at', r.created_at,
        'business_name', coalesce(b.storefront_name, b.business_name)))
    into v_out
    from app.care_reports r
    left join public.business_profiles b on b.user_id = r.business_id
    where r.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  if v_link.kind = 'starter' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'starter', jsonb_build_object(
        'business_name', coalesce(b.storefront_name, b.business_name)))
    into v_out
    from public.business_profiles b
    where b.user_id = v_link.ref_id and b.status = 'approved';
    return coalesce(v_out, jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'starter', jsonb_build_object('business_name', null)));
  end if;

  if v_link.kind = 'post' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'post', jsonb_build_object(
        -- id: 웹앱 CTA(app.pawmate.kr/p/<id>) 주소 생성용 — 이번 변경의 전부.
        'id', p.id,
        'category', p.category, 'title', p.title, 'content', p.content,
        'image_url', p.image_url, 'image_mime', p.image_mime_type,
        'image_thumb_url', p.image_thumbnail_url,
        'created_at', p.created_at,
        'author_name', case
          when p.category = 'news'
            then coalesce(b.storefront_name, b.business_name, pr.nickname)
          else pr.nickname end))
    into v_out
    from public.posts p
    left join public.public_profiles pr on pr.id = p.user_id
    left join public.business_profiles b
      on p.category = 'news' and b.user_id = p.user_id
    where p.id = v_link.ref_id and p.visibility_status = 'visible';
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;

-- 권한은 기존과 동일(변경 없음) — 명시적으로 재확인만 한다.
revoke all on function public.share_view_load(varchar) from public;
revoke execute on function public.share_view_load(varchar) from anon, authenticated;
grant execute on function public.share_view_load(varchar) to service_role;
