-- ============================================================================
-- 게시글 공유 — 모든 카테고리 게시글을 공유 뷰어 링크로 (0028 §3 인프라 재사용)
--
--  · 앱 상세 화면의 공유 버튼 → create_post_share_link → go.pawmate.kr/s?t=…
--    로그인 없이 열람(설치 전 가치 원칙). 뷰어는 앱 게시글 상세 디자인 미러.
--  · 링크는 게시글당 1개 재사용(유효 링크 존재 시), 만료 30일.
--  · 열람 시점 검증: 게시글이 삭제·숨김이면 not_found — 링크 발급 후 상태가
--    바뀌어도 노출되지 않는다(발급 시점이 아니라 로드 시점 기준).
--  · 노출 필드 최소: 카테고리·제목·본문·미디어·작성자 표시명(소식은 상호)·
--    작성일. 좌표·전화·지역코드는 노출하지 않는다.
-- ============================================================================

-- (1) kind 확장
alter table app.share_links drop constraint share_links_kind_check;
alter table app.share_links add constraint share_links_kind_check
  check (kind in ('facility_preview', 'care_report', 'starter', 'post'));

-- (2) 공유 링크 발급 — 로그인 사용자 누구나(타인 글 공유도 일반 패턴).
create or replace function public.create_post_share_link(p_post uuid)
returns table (token varchar, expires_at timestamptz)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_token varchar(32);
  v_exp   timestamptz;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.posts p
                  where p.id = p_post and p.visibility_status = 'visible') then
    raise exception 'post_not_found' using errcode = 'P0001';
  end if;

  select l.token, l.expires_at into v_token, v_exp
  from app.share_links l
  where l.kind = 'post' and l.ref_id = p_post
    and l.revoked_at is null and l.expires_at > now()
  order by l.created_at desc limit 1;
  if v_token is not null then
    return query select v_token, v_exp;
    return;
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp   := now() + interval '30 days';
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'post', p_post, v_uid, v_exp);
  insert into app.funnel_events (event, token, user_id)
  values ('post_share', v_token, v_uid);
  return query select v_token, v_exp;
end;
$function$;
revoke all on function public.create_post_share_link(uuid) from public;
grant execute on function public.create_post_share_link(uuid) to authenticated;

-- (3) 뷰어 — post 분기(로드 시점 가시성 검증, 소식은 상호 표기)
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
