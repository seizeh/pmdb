-- ============================================================================
-- 0028 P2 — 위탁 알림장 서버: care_threads · 반복 발행 · 스레드 claim
--
-- 키즈노트 모델(0028 §4.4): 스레드 = 반려동물 × 업체 관계 **상시 1개**,
-- '위탁 건' 엔티티는 만들지 않는다(수동 종료는 잊히고 날짜 기반은 깨진다).
--  · 기록(care_reports kind='boarding')은 스레드에 시간순으로 쌓이고 날짜
--    그룹핑은 앱이 담당. '건' 경계는 UI 구분선일 뿐이다.
--  · 자동 보관은 **파생값**(마지막 기록 N일 경과) — 상태 저장·크론 불필요,
--    새 기록이 오면 자연 복귀. 임계는 care_config.boarding_archive_days
--    (기본 7, 주중 등원형 오탐 확인 시 10으로 무마이그레이션 조정, §10-1).
--  · claim 은 스레드 단위 — 보호자가 한 번 연결되면 이후 발행이 자동으로
--    보이고 발행 알림을 받는다. 수신자 번호는 스레드에 한 번만(선택 입력).
--  · 미가입 보호자는 매 발행마다 단건 링크(kind='care_report', 기존 뷰어
--    파이프라인 재사용)를 업체가 재전송한다 — 스레드 전체 웹 뷰는 만들지
--    않는다(개인정보 최소, 0028 원칙 6).
-- ============================================================================

-- (1) 보관 임계 설정(0028 §10-1 — 설정 테이블로 무마이그레이션 튜닝)
alter table app.care_config
  add column if not exists boarding_archive_days smallint not null default 7;

-- (2) 스레드 — 반려동물 × 업체 상시 관계.
--     (business_id, pet_label) 유니크는 두지 않는다 — 같은 이름의 두 아이
--     (다른 보호자의 '초코' 둘)가 실존하므로 스레드 선택은 업체 UI 가 담당.
create table app.care_threads (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.users(id) on delete cascade,
  pet_label     varchar(50) not null,
  recipient_phone_hmac  bytea,       -- 스레드 단위 수신자(발행마다 묻지 않게). claim 성사 시 파기
  recipient_key_version smallint not null default 1,
  claimed_by    uuid references public.users(id),
  claimed_at    timestamptz,
  last_report_at timestamptz,        -- 보관 파생 기준(발행 시 갱신)
  created_at    timestamptz not null default now()
);
create index care_threads_business_idx on app.care_threads (business_id, last_report_at desc nulls last);
create index care_threads_phone_idx on app.care_threads (recipient_phone_hmac)
  where claimed_by is null and recipient_phone_hmac is not null;
create index care_threads_claimed_idx on app.care_threads (claimed_by);
comment on table app.care_threads is
  '위탁 알림장 스레드(0028 §4.4) — 반려동물×업체 상시 1개, 건 엔티티 없음.';

-- 기록 → 스레드 연결(boarding 전용, grooming 단건은 null 유지)
alter table app.care_reports
  add column if not exists thread_id uuid references app.care_threads(id) on delete cascade;
create index care_reports_thread_idx on app.care_reports (thread_id, created_at desc)
  where thread_id is not null;

-- (3) 스레드 생성 — has_license('boarding') 게이트
create or replace function public.create_care_thread(
  p_pet_label text,
  p_recipient_phone text default null
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_label text := nullif(btrim(coalesce(p_pet_label, '')), '');
  v_hmac bytea;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not app.has_license('boarding') then
    raise exception 'license_required' using errcode = 'P0001';
  end if;
  if v_label is null or length(v_label) > 50 then
    raise exception 'invalid_pet_label' using errcode = 'P0001';
  end if;
  if p_recipient_phone is not null and btrim(p_recipient_phone) <> '' then
    v_hmac := app.phone_hmac(p_recipient_phone);
    if v_hmac is null then
      raise exception 'invalid_phone' using errcode = 'P0001';
    end if;
  end if;

  insert into app.care_threads
    (business_id, pet_label, recipient_phone_hmac, recipient_key_version)
  values (v_uid, v_label, v_hmac,
          (select key_version from app.care_config))
  returning id into v_id;
  return v_id;
end;
$function$;
revoke all on function public.create_care_thread(text, text) from public;
grant execute on function public.create_care_thread(text, text) to authenticated;

-- (4) 알림장 발행 — 스레드에 기록 추가 + 단건 공유 링크 + 연결 보호자 알림.
--     [p_body] 는 kind 별 구조 필드(식사·배변·컨디션 등) — 앱이 스키마를 정한다.
create or replace function public.create_boarding_report(
  p_thread uuid,
  p_photos jsonb default '[]',
  p_body jsonb default '{}',
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_thread app.care_threads%rowtype;
  v_report uuid;
  v_token varchar(32);
  v_exp timestamptz;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not app.has_license('boarding') then
    raise exception 'license_required' using errcode = 'P0001';
  end if;
  select * into v_thread from app.care_threads
   where id = p_thread and business_id = v_uid;
  if not found then
    raise exception 'thread_not_found' using errcode = 'P0001';
  end if;
  if jsonb_typeof(coalesce(p_photos, '[]'::jsonb)) is distinct from 'array'
     or jsonb_array_length(coalesce(p_photos, '[]'::jsonb)) > 4 then
    raise exception 'invalid_photos' using errcode = 'P0001';
  end if;
  if jsonb_typeof(coalesce(p_body, '{}'::jsonb)) is distinct from 'object' then
    raise exception 'invalid_body' using errcode = 'P0001';
  end if;
  -- 사진 없이 글만 있는 알림장도 허용하되, 둘 다 비면 거부.
  if jsonb_array_length(coalesce(p_photos, '[]'::jsonb)) = 0
     and coalesce(p_body, '{}'::jsonb) = '{}'::jsonb
     and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'empty_report' using errcode = 'P0001';
  end if;

  insert into app.care_reports
    (business_id, kind, pet_label, photos, body, note, thread_id, claimed_by, claimed_at)
  values
    (v_uid, 'boarding', v_thread.pet_label, coalesce(p_photos, '[]'::jsonb),
     coalesce(p_body, '{}'::jsonb), nullif(btrim(coalesce(p_note, '')), ''),
     p_thread,
     -- 스레드가 이미 연결돼 있으면 기록도 즉시 연결 상태로.
     v_thread.claimed_by, case when v_thread.claimed_by is null then null else now() end)
  returning id into v_report;

  update app.care_threads set last_report_at = now() where id = p_thread;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp := now() + interval '30 days';
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'care_report', v_report, v_uid, v_exp);

  insert into app.funnel_events (event, token, user_id)
  values ('report_issued', v_token, v_uid);

  -- 연결 보호자에겐 발행 즉시 도착 알림(0028 §4.4 — 인앱 파이프라인).
  if v_thread.claimed_by is not null then
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_thread.claimed_by, 'system_notice', true,
            v_thread.pet_label || ' 돌봄 기록이 도착했어요',
            '오늘의 ' || v_thread.pet_label || ' 소식을 앱에서 확인해 보세요.');
  end if;

  return jsonb_build_object('report_id', v_report, 'token', v_token, 'expires_at', v_exp);
end;
$function$;
revoke all on function public.create_boarding_report(uuid, jsonb, jsonb, text) from public;
grant execute on function public.create_boarding_report(uuid, jsonb, jsonb, text) to authenticated;

-- (5) 업체 스레드 목록 — 보관은 파생값(archived), 새 기록이 오면 자연 복귀.
create or replace function public.my_care_threads(
  p_limit integer default 50,
  p_offset integer default 0
) returns table (
  id uuid, pet_label text, claimed_nickname text,
  last_report_at timestamptz, report_count integer,
  last_photo text, archived boolean
)
language sql stable security definer
set search_path to ''
as $$
  select t.id, t.pet_label::text, pr.nickname::text,
         t.last_report_at,
         (select count(*)::int from app.care_reports r where r.thread_id = t.id),
         (select r.photos->>0 from app.care_reports r
           where r.thread_id = t.id and jsonb_array_length(r.photos) > 0
           order by r.created_at desc limit 1),
         coalesce(
           t.last_report_at < now() - make_interval(
             days => (select boarding_archive_days from app.care_config)),
           false)
    from app.care_threads t
    left join public.public_profiles pr on pr.id = t.claimed_by
   where t.business_id = app.uid()
   order by t.last_report_at desc nulls last
   limit least(coalesce(p_limit, 50), 200) offset coalesce(p_offset, 0);
$$;
revoke all on function public.my_care_threads(integer, integer) from public;
grant execute on function public.my_care_threads(integer, integer) to authenticated;

-- (6) 스레드 기록 조회 — 업체(소유) 또는 연결 보호자만. 날짜 그룹핑은 앱.
create or replace function public.care_thread_reports(
  p_thread uuid,
  p_limit integer default 100,
  p_offset integer default 0
) returns table (
  id uuid, photos jsonb, body jsonb, note text, created_at timestamptz, token text
)
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not exists (select 1 from app.care_threads t
                 where t.id = p_thread
                   and (t.business_id = v_uid or t.claimed_by = v_uid)) then
    raise exception 'thread_not_found' using errcode = 'P0001';
  end if;
  return query
  select r.id, r.photos, r.body, r.note, r.created_at, l.token::text
    from app.care_reports r
    left join app.share_links l on l.kind = 'care_report' and l.ref_id = r.id
   where r.thread_id = p_thread
   order by r.created_at desc
   limit least(coalesce(p_limit, 100), 300) offset coalesce(p_offset, 0);
end;
$function$;
revoke all on function public.care_thread_reports(uuid, integer, integer) from public;
grant execute on function public.care_thread_reports(uuid, integer, integer) to authenticated;

-- (7) claim 확장 — 스레드 단위 자동 연결(리포트 단건 claim 은 기존 유지).
--     스레드 연결 시 그 스레드의 기존 기록도 함께 열린다.
create or replace function public.claim_care_reports()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_hmac bytea;
  v_cnt integer := 0;
  r record;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  select app.phone_hmac(u.phone) into v_hmac from public.users u where u.id = v_uid;
  if v_hmac is null then return 0; end if;

  -- 단건 리포트(미용 전후 사진 등) 자동 연결
  for r in
    update app.care_reports cr
       set claimed_by = v_uid, claimed_at = now(), recipient_phone_hmac = null
     where cr.recipient_phone_hmac = v_hmac
       and cr.claimed_by is null
       and cr.business_id <> v_uid
    returning cr.id, cr.pet_label
  loop
    v_cnt := v_cnt + 1;
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_uid, 'system_notice', true,
            r.pet_label || ' 케어 기록이 도착했어요',
            '업체가 보내준 ' || r.pet_label || ' 사진을 앱에서 확인해 보세요.');
    insert into app.funnel_events (event, token, user_id)
    select 'claim', l.token, v_uid
      from app.share_links l
     where l.kind = 'care_report' and l.ref_id = r.id;
  end loop;

  -- 스레드(알림장) 자동 연결 — 기존 기록도 함께 연결 처리
  for r in
    update app.care_threads t
       set claimed_by = v_uid, claimed_at = now(), recipient_phone_hmac = null
     where t.recipient_phone_hmac = v_hmac
       and t.claimed_by is null
       and t.business_id <> v_uid
    returning t.id, t.pet_label
  loop
    v_cnt := v_cnt + 1;
    update app.care_reports set claimed_by = v_uid, claimed_at = now()
     where thread_id = r.id and claimed_by is null;
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_uid, 'system_notice', true,
            r.pet_label || ' 알림장이 연결됐어요',
            '이제 ' || r.pet_label || ' 돌봄 기록이 도착할 때마다 알려드려요.');
    insert into app.funnel_events (event, user_id, props)
    values ('claim', v_uid, jsonb_build_object('thread_id', r.id));
  end loop;

  return v_cnt;
end;
$function$;

-- (8) 받은 기록에 스레드 기록 포함(thread_id 노출 — 앱 스레드 화면용)
drop function if exists public.my_received_care_reports(integer, integer);
create function public.my_received_care_reports(
  p_limit integer default 30,
  p_offset integer default 0
) returns table (
  id uuid, kind text, pet_label text, photos jsonb, body jsonb, note text,
  created_at timestamptz, business_name text, thread_id uuid
)
language sql stable security definer
set search_path to ''
as $$
  select r.id, r.kind::text, r.pet_label::text, r.photos, r.body, r.note,
         r.created_at, coalesce(b.storefront_name, b.business_name)::text,
         r.thread_id
    from app.care_reports r
    left join public.business_profiles b on b.user_id = r.business_id
   where r.claimed_by = app.uid()
   order by r.created_at desc
   limit least(coalesce(p_limit, 30), 100) offset coalesce(p_offset, 0);
$$;
revoke all on function public.my_received_care_reports(integer, integer) from public;
grant execute on function public.my_received_care_reports(integer, integer) to authenticated;

-- (9) 뷰어 — care_report 에 kind·body 노출(알림장 렌더용)
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
                 'photo_urls', r.photos)
                 order by r.has_photo desc, r.created_at desc)
        from (select rating, content, has_incentive, created_at,
                     coalesce(array_length(photo_urls, 1), 0) > 0 as has_photo,
                     (select coalesce(jsonb_agg(u), '[]'::jsonb)
                        from unnest(photo_urls[1:2]) u) as photos
              from public.facility_reviews
              where facility_id = f.id and visibility_status = 'visible'
              order by coalesce(array_length(photo_urls, 1), 0) > 0 desc,
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

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;

-- (10) 미연결 스레드 hmac 파기 — 마지막 발행 30일 경과(§4.2 준용, 기존 크론 확장)
do $$ begin
  if exists (select 1 from cron.job where jobname = 'care-report-hmac-purge') then
    perform cron.unschedule('care-report-hmac-purge');
  end if;
end $$;
select cron.schedule('care-report-hmac-purge', '58 3 * * *',
  $$update app.care_reports r set recipient_phone_hmac = null
     where r.recipient_phone_hmac is not null and r.claimed_by is null
       and exists (select 1 from app.share_links l
                    where l.kind = 'care_report' and l.ref_id = r.id
                      and l.expires_at < now());
    update app.care_threads t set recipient_phone_hmac = null
     where t.recipient_phone_hmac is not null and t.claimed_by is null
       and coalesce(t.last_report_at, t.created_at) < now() - interval '30 days'$$);
