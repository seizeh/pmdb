-- ============================================================================
-- 0028 §6 — 대가성 후기 표시 (표시광고법 경제적 이해관계 표시 의무)
--
-- 업체가 후기 대가로 할인·사은품을 주는 순간 경제적 이해관계 표시 의무가 생긴다
-- (공정위 추천·보증 심사지침). 작성자가 체크한 사실을 저장하고, 모든 노출면
-- (앱 후기 카드·상세, share-view 공개 뷰어)에 배지로 표시한다.
--
-- 시그니처 변경 규칙: 구버전을 반드시 drop — 오버로드가 공존하면 PostgREST 가
-- 구버전을 호출한다. 새 파라미터는 default 라 구버전 앱(5개 인자 호출)도 그대로
-- 동작한다(named-arg 매칭 + default 충전).
-- 읽기 RPC 는 RETURNS TABLE 변경이라 create or replace 불가 → drop 후 재생성,
-- GRANT 재부여(구버전 앱은 늘어난 컬럼을 무시하므로 호환).
-- ============================================================================

alter table public.facility_reviews
  add column if not exists has_incentive boolean not null default false;
comment on column public.facility_reviews.has_incentive is
  '업체로부터 할인·사은품 등 혜택을 받고 작성 — 표시광고법 표시 의무(0028 §6)';

-- (1) 작성 RPC — p_has_incentive 추가 (프로덕션 현재 정의 기준 + 컬럼 1개)
drop function if exists public.add_facility_review(uuid, smallint, text, text[], text[]);
create function public.add_facility_review(
  p_facility uuid, p_rating smallint, p_body text,
  p_paths text[] default '{}', p_urls text[] default '{}',
  p_has_incentive boolean default false
) returns uuid language plpgsql security definer set search_path to '' as $$
declare v_uid uuid := app.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;
  if exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_uid
       and bp.status in ('pending', 'approved')
       and bp.matched_facility_id = any(public.facility_sibling_ids(p_facility))
  ) then
    raise exception 'own_facility' using errcode = 'P0001';
  end if;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls, has_incentive)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'), coalesce(p_has_incentive, false))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.add_facility_review(uuid,smallint,text,text[],text[],boolean) from public;
grant execute on function public.add_facility_review(uuid,smallint,text,text[],text[],boolean) to authenticated;

-- (2) 목록 RPC — has_incentive 컬럼 추가(반환형 변경 → drop 재생성)
drop function if exists public.facility_reviews_of(uuid, integer, integer);
create function public.facility_reviews_of(
  p_facility uuid, p_limit integer default 20, p_offset integer default 0
) returns table(
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean, visit_no integer,
  has_incentive boolean
)
language sql stable security definer set search_path to '' as $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no, r.has_incentive
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.facility_id = any(public.facility_sibling_ids(p_facility))
         and fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$$;
revoke all on function public.facility_reviews_of(uuid, integer, integer) from public;
grant execute on function public.facility_reviews_of(uuid, integer, integer) to authenticated, service_role;

-- (3) 단건 RPC — 동일하게 has_incentive 추가
drop function if exists public.facility_review_by_id(uuid);
create function public.facility_review_by_id(p_review uuid)
returns table(
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean, visit_no integer,
  has_incentive boolean
)
language sql stable security definer set search_path to '' as $$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no, r.has_incentive
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
$$;
revoke all on function public.facility_review_by_id(uuid) from public;
grant execute on function public.facility_review_by_id(uuid) to authenticated, service_role;

-- (4) 공개 뷰어(share-view)의 후기에도 배지 데이터 노출 — jsonb 반환이라 교체만
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
        'avg_rating', f.avg_rating, 'review_count', f.review_count),
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
    from public.facilities f where f.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;
