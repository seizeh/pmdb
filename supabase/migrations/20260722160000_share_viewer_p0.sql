-- ============================================================================
-- 0028 P0 — 공유 뷰어 기반: share_links · funnel_events · 발급/회수 RPC
--
-- 설치 전 가치 전달의 공통 기반(0028 §3). 토큰 링크는 share-view Edge Function
-- 이 로그인 없이 HTML 로 서빙하고, 열람·클릭은 funnel_events 에 계측된다(§7).
-- P0 은 kind='facility_preview'(매장 QR 미리보기)만 발급 — 'care_report' 는
-- P1(미용 전후 사진)에서 열린다(kind CHECK 에 미리 포함, 발급 RPC 는 P1 에서).
--
-- 접근 모델: 두 테이블 모두 app 스키마(클라이언트 롤에 USAGE 없음) — 읽기/쓰기는
-- Edge Function(service_role)과 아래 SECURITY DEFINER RPC 로만.
-- ============================================================================

-- (1) 공유 링크 — 토큰은 16바이트 랜덤 hex 32자(서버 생성, 추측 불가)
create table app.share_links (
  token       varchar(32) primary key,
  kind        varchar(20) not null
              check (kind in ('facility_preview', 'care_report')),
  ref_id      uuid not null,                 -- kind 별 대상(시설 id, 리포트 id …)
  created_by  uuid not null references public.users(id) on delete cascade,
  expires_at  timestamptz not null,
  view_count  integer not null default 0,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index share_links_ref_idx on app.share_links (kind, ref_id); -- 대상→링크 역조회
comment on table app.share_links is
  '설치 전 가치 전달용 공유 링크(0028 §3). share-view Edge Function 이 서빙.';

-- (2) 파일럿 퍼널 계측 — 원시 이벤트 보존 1년(경과분 배치 삭제, 0028 §7)
create table app.funnel_events (
  id          bigint generated always as identity primary key,
  event       varchar(30) not null,          -- share_view | store_click | signup | claim | ...
  token       varchar(32),                   -- share_links 귀속(있으면)
  user_id     uuid,                          -- 가입 이후 이벤트만
  props       jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index funnel_events_token_idx on app.funnel_events (token, event); -- 매장·도구별 전환 집계
comment on table app.funnel_events is
  '오프라인 제휴 파일럿 퍼널 계측(0028 §7). 원시 이벤트 보존 1년.';

-- (3) 매장 미리보기 링크 발급 — 관리자 전용(QR 캠페인 운영 도구).
--     같은 시설의 유효 링크가 이미 있으면 그 토큰을 재사용한다(매장당 QR 1장 원칙,
--     재호출로 기존 인쇄물이 무효화되지 않게).
create or replace function public.admin_create_facility_share_link(
  p_facility uuid,
  p_days integer default 365
) returns table (token varchar, expires_at timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_token varchar(32);
  v_exp   timestamptz;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_days < 1 or p_days > 3650 then
    raise exception 'days 1..3650';
  end if;
  if not exists (select 1 from public.facilities f where f.id = p_facility) then
    raise exception 'facility not found';
  end if;

  -- 유효(미회수·미만료) 링크 재사용
  select l.token, l.expires_at into v_token, v_exp
  from app.share_links l
  where l.kind = 'facility_preview' and l.ref_id = p_facility
    and l.revoked_at is null and l.expires_at > now()
  order by l.created_at desc limit 1;
  if v_token is not null then
    return query select v_token, v_exp;
    return;
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp   := now() + make_interval(days => p_days);
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'facility_preview', p_facility, app.uid(), v_exp);
  return query select v_token, v_exp;
end;
$function$;
revoke all on function public.admin_create_facility_share_link(uuid, integer) from public;
grant execute on function public.admin_create_facility_share_link(uuid, integer) to authenticated;

-- (4) share-view 전용 조회+계측 RPC — service_role 만 실행 가능.
--     app 스키마는 PostgREST 에 노출되지 않으므로 Edge Function 도 직접 못 읽는다 —
--     public RPC 하나로 검증·데이터·계측을 원자 처리(단일 왕복, view_count 원자 증가).
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
        select jsonb_agg(jsonb_build_object('rating', r.rating, 'content', r.content)
                         order by r.created_at desc)
        from (select rating, content, created_at
              from public.facility_reviews
              where facility_id = f.id and visibility_status = 'visible'
              order by created_at desc limit 3) r), '[]'::jsonb))
    into v_out
    from public.facilities f where f.id = v_link.ref_id;
    return coalesce(v_out, jsonb_build_object('status', 'not_found'));
  end if;

  -- care_report 등 P1 kind — 링크는 유효하나 뷰어 본문은 아직(안내 페이지)
  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;
revoke all on function public.share_view_load(varchar) from public;
revoke execute on function public.share_view_load(varchar) from anon, authenticated;
grant execute on function public.share_view_load(varchar) to service_role;

-- (5) 스토어 클릭 계측 — service_role 전용. 유효 링크일 때만 기록.
create or replace function public.share_view_click(p_token varchar)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (select 1 from app.share_links
                 where token = p_token and revoked_at is null and expires_at > now()) then
    return false;
  end if;
  insert into app.funnel_events (event, token) values ('store_click', p_token);
  return true;
end;
$function$;
revoke all on function public.share_view_click(varchar) from public;
revoke execute on function public.share_view_click(varchar) from anon, authenticated;
grant execute on function public.share_view_click(varchar) to service_role;

-- (6) 링크 회수 — 관리자 전용(오배포·유출 대응)
create or replace function public.admin_revoke_share_link(p_token varchar)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update app.share_links set revoked_at = now()
  where token = p_token and revoked_at is null;
  return found;
end;
$function$;
revoke all on function public.admin_revoke_share_link(varchar) from public;
grant execute on function public.admin_revoke_share_link(varchar) to authenticated;
