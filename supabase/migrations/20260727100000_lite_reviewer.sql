-- 간이 회원(lite) — 후기 작성 전용 비회원 계정 (0029 P0)
--
-- 목적: QR·공유 링크로 들어온 손님이 정식 가입(아이디·비밀번호·닉네임·약관 전체)
-- 없이 **전화번호 인증만으로 후기를 남기게** 한다. 진입점은 후기 작성 플로우 하나뿐.
--
-- 설계의 핵심 두 가지:
--
-- 1) **계정은 처음부터 하나다(병합이 아니라 승격).**
--    users.phone 에 유니크 인덱스(users_phone_uq)가 있어 같은 번호는 같은 행일
--    수밖에 없다. 간이로 쓴 뒤 정식 가입하면 새 행을 만드는 게 아니라 그 행에
--    username/password_hash/nickname 을 채운다. 덕분에 facility_reviews_of 의
--    visit_no(= user_id 파티션 row_number)가 끊기지 않고 "3번째 방문"으로 이어진다.
--    반대로 승격을 안 하면 signup_user 가 phone_taken 으로 **정식 가입을 막는다.**
--
-- 2) **간이 회원은 비회원 취급 — 기본 전면 차단, 후기만 예외.**
--    app.uid() 가 status='active' 를 요구하므로 status='lite' 로 두면 RLS·RPC 가
--    전부 자동으로 막힌다(채팅·게시글·펫 등 어디에도 손댈 필요 없음). 후기 작성
--    하나만 app.uid_lite() 로 뚫는다. 새 기능이 생겨도 기본값이 차단이라 안전하다.
--
-- 매 작성마다 재인증: 간이 계정은 세션을 들고 다니지 않는다. 후기를 쓸 때마다
-- purpose='review' 전화 인증을 새로 받게 하고, 그 사실을 **서버에서** 확인한다
-- (클라이언트만 막으면 우회된다).

begin;

-- ── 1. status 도메인에 'lite' 추가 ────────────────────────────────────────────
-- CHECK 를 안 고치면 INSERT 가 조용히가 아니라 요란하게 실패한다. 값 추가는
-- 언제나 제약 수정과 한 세트다.
alter table public.users drop constraint if exists users_status_check;
alter table public.users add constraint users_status_check
  check (status in ('active', 'inactive', 'suspended', 'deleted', 'lite'));

comment on column public.users.status is
  'active=정식 회원 · lite=후기 전용 간이 회원(비회원 취급, app.uid() 에서 제외) · '
  'inactive=휴면 · suspended=정지 · deleted=탈퇴';

-- ── 1-2. 전화 인증 목적에 'review' 추가 ──────────────────────────────────────
-- 간이 후기는 'signup' 목적을 재사용할 수 없다. send-phone-code 가 signup 목적은
-- **이미 가입된 번호에 발송을 거부**하는데(index.ts:61), 간이 후기는 정식 회원도
-- 쓸 수 있어야 하기 때문이다. 목적을 분리하면 그 차단과 무관해지고, 후기용
-- 인증이 가입에 전용되는 일도 막힌다.
alter table public.phone_verifications
  drop constraint if exists phone_verifications_purpose_check;
alter table public.phone_verifications add constraint phone_verifications_purpose_check
  check (purpose in ('signup', 'password_reset', 'review'));

-- ── 2. 전화번호 마스크 ────────────────────────────────────────────────────────
-- 표시 규칙: 앞 3자리(010)는 전부 가리고, 가운데 4자리 중 앞 1자리, 끝 2자리만
-- 노출한다 → '***-1***-**78'. 본인은 알아보고 남은 식별력은 낮다.
--
-- ⚠️ 이 값을 users.nickname 에 넣으면 안 된다 — 조합이 1,000가지뿐인데 nickname 은
-- 대소문자 무시 유니크(users_lower_nickname_uq)라 즉시 충돌한다. nickname 에는
-- 비노출 내부값(lite_<hex>)을 넣고, 표시는 조회 시점에 이 함수로 만든다.
create or replace function app.mask_phone(p_phone text)
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when d is null or length(d) < 4 then '***-****-****'
    when length(d) >= 11 then
      '***-' || substr(d, 4, 1) || '***-**' || right(d, 2)
    -- 10자리 등 비표준 번호는 끝 2자리만 — 자리수를 억지로 맞추지 않는다.
    else '***-****-**' || right(d, 2)
  end
  from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d) t;
$$;

comment on function app.mask_phone(text) is
  '간이 회원 표시명 — 010 전체 마스킹 + 가운데 앞 1자리 + 끝 2자리(***-1***-**78).';

-- ── 3. 후기 작성용 uid 해석 ──────────────────────────────────────────────────
-- app.uid() 와 같되 status='lite' 도 통과시킨다. **add_facility_review 에서만**
-- 쓴다. 다른 데서 쓰면 간이 회원이 비회원이라는 전제가 무너진다.
create or replace function app.uid_lite()
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select u.id
  from public.users u
  where u.id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'sub','')::uuid
    and u.status in ('active', 'lite')
    and u.token_version = coalesce(
      ((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'tv')::int, 0)
$$;

comment on function app.uid_lite() is
  '후기 작성 전용 uid — active + lite 허용. 이 함수를 다른 기능에 쓰지 말 것'
  '(간이 회원은 후기 외 모든 기능에서 비회원이어야 한다).';

-- ── 4. 간이 회원 생성 ────────────────────────────────────────────────────────
-- service_role 전용(엣지 함수 signup-lite 경유). 같은 번호가 이미 있으면 새로
-- 만들지 않고 그 계정을 그대로 돌려준다 — 재방문·정식 회원의 간이 경로 진입 모두
-- 같은 계정으로 수렴해야 visit_no 가 이어진다.
create or replace function public.signup_lite_user(
  p_phone text,
  p_privacy_consent boolean default false
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id     uuid;
  v_status text;
  v_hex    text;
begin
  -- 개인정보(전화번호) 수집·이용 동의는 필수. 클라이언트 체크박스만 믿지 않는다.
  if coalesce(p_privacy_consent, false) is not true then
    raise exception 'privacy_consent_required' using errcode = 'P0001';
  end if;

  -- 후기 목적 전화 인증 확인(30분 이내). purpose 를 'signup' 과 분리하는 이유:
  -- send-phone-code 가 signup 목적은 "이미 가입된 번호"에 발송을 거부하는데,
  -- 간이 후기는 정식 회원이 쓸 수도 있어 그 차단에 걸리면 안 된다.
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'review'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  select id, status into v_id, v_status
    from public.users where phone = p_phone;

  if found then
    -- 정지·탈퇴 계정이 간이 경로로 되살아나면 안 된다.
    if v_status in ('suspended', 'deleted') then
      raise exception 'account_unavailable' using errcode = 'P0001';
    end if;
    return v_id;
  end if;

  -- username/nickname 은 NOT NULL + 유니크라 값이 필요하지만 사용자에게는 보이지
  -- 않는다(표시는 app.mask_phone). password_hash 는 argon2id/bcrypt 어느 쪽으로도
  -- 검증에 성공할 수 없는 sentinel — 비밀번호 로그인 경로를 원천 차단한다.
  -- gen_random_uuid() 는 pg_catalog 라 search_path='' 에서도 그냥 보인다.
  -- (pgcrypto 의 gen_random_bytes 는 extensions 스키마라 여기서 안 보인다.)
  v_hex := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);

  insert into public.users (
    username, password_hash, nickname, user_type, phone, phone_verified,
    status, terms_agreed_at
  ) values (
    'lite_' || v_hex,
    '!',
    'lite_' || v_hex,
    'no_pet',
    p_phone,
    true,
    'lite',
    now()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.signup_lite_user(text, boolean) from public, anon, authenticated;
grant execute on function public.signup_lite_user(text, boolean) to service_role;

comment on function public.signup_lite_user(text, boolean) is
  '간이 회원 생성/조회 — 엣지 signup-lite 전용(service_role). 같은 번호는 항상 같은 계정.';

-- ── 5. 정식 가입에서 간이 계정 승격 ──────────────────────────────────────────
-- 기존 동작과 달라지는 지점은 하나다: 같은 번호가 **lite** 로 존재하면
-- phone_taken 대신 그 행을 UPDATE 해서 정식 회원으로 올린다. 이미 쓴 후기는
-- user_id 가 그대로라 자동으로 따라오고, visit_no 도 이어진다.
create or replace function public.signup_user(
  p_username text,
  p_password_hash text,
  p_nickname text,
  p_user_type text,
  p_phone text,
  p_marketing boolean default false
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id     uuid;
  v_status text;
begin
  -- 1) 전화 인증 완료 확인 (signup 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'signup'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  -- 2) 중복 사전 검사 (유니크 인덱스가 최종 방어선, 여기선 친절한 에러코드용)
  if exists (select 1 from public.users where lower(username) = lower(p_username)) then
    raise exception 'username_taken' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.users where lower(nickname) = lower(p_nickname)) then
    raise exception 'nickname_taken' using errcode = 'P0001';
  end if;

  -- 3) 같은 번호가 이미 있으면 — lite 면 승격, 그 외엔 기존대로 거부.
  select id, status into v_id, v_status
    from public.users where phone = p_phone;

  if found then
    if v_status <> 'lite' then
      raise exception 'phone_taken' using errcode = 'P0001';
    end if;
    update public.users set
      username            = p_username,
      password_hash       = p_password_hash,
      nickname            = p_nickname,
      user_type           = p_user_type,
      status              = 'active',
      terms_agreed_at     = now(),
      marketing_opt_in    = coalesce(p_marketing, false),
      marketing_opt_in_at = case when coalesce(p_marketing, false) then now() else null end,
      updated_at          = now()
    where id = v_id;
    return v_id;
  end if;

  -- 4) 신규 INSERT (해시는 엣지에서 argon2id 로 생성, 필수 약관 동의 시각 기록)
  insert into public.users (
    username, password_hash, nickname, user_type, phone, phone_verified,
    terms_agreed_at, marketing_opt_in, marketing_opt_in_at
  ) values (
    p_username,
    p_password_hash,
    p_nickname,
    p_user_type,
    p_phone,
    true,
    now(),
    coalesce(p_marketing, false),
    case when coalesce(p_marketing, false) then now() else null end
  )
  returning id into v_id;

  return v_id;
end;
$function$;

-- ── 6. 후기 작성 — 간이 회원 허용 + 매 작성 재인증 강제 ──────────────────────
-- 바뀐 곳: app.uid() → app.uid_lite(), 그리고 lite 계정이면 최근 15분 내
-- purpose='review' 인증을 요구한다. 클라이언트가 아무리 우회해도 여기서 막힌다.
create or replace function public.add_facility_review(
  p_facility uuid,
  p_rating smallint,
  p_body text,
  p_paths text[] default '{}'::text[],
  p_urls text[] default '{}'::text[],
  p_has_incentive boolean default false,
  p_videos jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid    uuid := app.uid_lite();
  v_id     uuid;
  v        jsonb;
  v_status text;
  v_phone  text;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;

  select status, phone into v_status, v_phone
    from public.users where id = v_uid;

  -- 간이 회원은 후기 한 건마다 전화 인증을 새로 받는다(세션을 들고 다니지 않는다).
  if v_status = 'lite' then
    if not exists (
      select 1 from public.phone_verifications
      where phone = v_phone
        and purpose = 'review'
        and is_used = true
        and created_at > now() - interval '15 minutes'
    ) then
      raise exception 'reverify_required' using errcode = 'P0001';
    end if;
  end if;

  if exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_uid
       and bp.status in ('pending', 'approved')
       and bp.matched_facility_id = any(public.facility_sibling_ids(p_facility))
  ) then
    raise exception 'own_facility' using errcode = 'P0001';
  end if;
  -- 영상 검증 — 배열·개수는 CHECK 가 재검증하지만, 원소 형태는 여기서 명시 거부.
  if jsonb_typeof(coalesce(p_videos, '[]'::jsonb)) is distinct from 'array'
     or jsonb_array_length(coalesce(p_videos, '[]'::jsonb)) > 2 then
    raise exception 'invalid_videos' using errcode = 'P0001';
  end if;
  for v in select value from jsonb_array_elements(coalesce(p_videos, '[]'::jsonb))
  loop
    if jsonb_typeof(v) is distinct from 'object'
       or coalesce(v->>'url', '') = '' or length(v->>'url') > 500 then
      raise exception 'invalid_videos' using errcode = 'P0001';
    end if;
  end loop;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls,
     has_incentive, videos)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'),
          coalesce(p_has_incentive, false), coalesce(p_videos, '[]'::jsonb))
  returning id into v_id;
  return v_id;
end $function$;

-- ── 7. 후기 조회 — 간이 회원은 마스크로 표시 ─────────────────────────────────
-- author_nickname **값만** 바꾼다. 컬럼을 추가하면 RETURNS TABLE 이 달라져
-- create or replace 가 거부되고 drop 이 필요해지는데, 그러면 앱 구버전이
-- 잠시 깨진다. 값 치환은 그런 위험이 없다.
create or replace function public.facility_reviews_of(
  p_facility uuid,
  p_limit integer default 20,
  p_offset integer default 0
)
returns table(
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamp with time zone, is_mine boolean,
  visit_no integer, has_incentive boolean, videos jsonb
)
language sql
stable
security definer
set search_path to ''
as $function$
  select r.id, r.user_id,
         case when au.status = 'lite' then app.mask_phone(au.phone)
              else pr.nickname end,
         r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid_lite()) as is_mine, r.visit_no, r.has_incentive, r.videos
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
    left join public.users au on au.id = r.user_id
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$function$;

create or replace function public.facility_review_by_id(p_review uuid)
returns table(
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamp with time zone, is_mine boolean,
  visit_no integer, has_incentive boolean, videos jsonb
)
language sql
stable
security definer
set search_path to ''
as $function$
  select r.id, r.user_id,
         case when au.status = 'lite' then app.mask_phone(au.phone)
              else pr.nickname end,
         r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid_lite()) as is_mine, r.visit_no, r.has_incentive, r.videos
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
    left join public.users au on au.id = r.user_id
   where r.id = p_review;
$function$;

-- ── 7-2. 시설 이름 검색을 비로그인에 개방 ────────────────────────────────────
-- 시설은 '주인 없는 프로필'이라 손님이 상호로 찾아 후기까지 갈 수 있어야 하는데,
-- facilities_search 가 authenticated 전용이라 게스트 검색이 빈손으로 돌아왔다.
-- facilities 테이블 자체는 이미 RLS `using (true)` + anon SELECT 라 이 함수만
-- 열어도 새로 드러나는 정보는 없다(같은 데이터를 더 편하게 찾을 뿐).
--
-- 반경 조회(facilities_within)는 **열지 않는다** — 웹은 위치 수집을 하드 차단하고
-- 있어(0028 웹 이식) 좌표 기반 조회를 비로그인에 열 이유가 없다.
grant execute on function public.facilities_search(text, double precision, double precision) to anon;

-- ── 8. 공유 뷰어 — 후기 작성 딥링크용 facility_id ────────────────────────────
-- QR(facility_preview)로 들어온 사람은 곧바로 **그 매장의 후기 작성 화면**으로
-- 보낸다. 매장에서 QR 을 찍는 목적이 후기이기 때문이다.
--
-- 대상이 업체 프로필이 아니라 시설(facility)인 게 핵심이다: 업체 계정이 없는
-- 매장이 대부분인데(공공데이터로 들어온 시설이 24,000여 곳), 시설 자체가 이미
-- '주인 없는 프로필' 노릇을 한다. 나중에 그 매장이 업체 인증을 마치면
-- business_profiles.matched_facility_id 로 같은 시설에 붙어 수정 권한을 갖는다 —
-- 즉 QR 을 먼저 뿌려도 나중에 주인이 나타나는 순서가 자연스럽게 성립한다.
--
-- owner_user_id 도 함께 싣는다(업체 프로필로 보내는 `/u/` 링크용 — 현재 QR 은
-- 쓰지 않지만 공유 경로가 늘어날 때 재조회를 막는다).
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
        'id', f.id,
        'photo_url', bp.photo_url,
        'photo_align_y', coalesce(bp.photo_align_y, 0),
        'business_hours', bp.business_hours,
        'owner_user_id', bp.user_id,
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
      select true as verified, b.user_id, b.photo_url, b.photo_align_y, b.business_hours
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

commit;
