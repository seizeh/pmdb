-- ============================================================================
-- 0028 P1 — 케어 리포트(미용 전후 사진) 서버: care_reports · 발행/목록/claim RPC
--
-- "업체가 보호자에게 보내야 하는 순간을 앱이 독점한다"의 첫 도구. 미용 완료
-- 사진을 링크로 전달하고, 그 링크가 곧 가입 유도가 된다(0028 §4).
--
-- claim 설계(0028 §4.2 · 3차 개정):
--  · 1차 = 전화번호 HMAC 대조 자동 연결 — 가입/로그인 시 claim_care_reports()
--    호출로 대기 리포트가 자동 연결된다(경로 무관: QR·링크·스토어 검색).
--  · 전화번호는 **선택 입력**(§4.1 4차 개정) — 없으면 링크 열람만으로 가치 전달,
--    연결은 안 됨(토큰 claim·업체 승인 폴백은 앱 딥링크와 함께 후속).
--  · 키드 HMAC(무염 해시는 번호 전수대입에 취약), 키는 app.care_config 싱글턴.
--    claim 성사 시 hmac 즉시 파기, 미연결분은 링크 만료(30일)와 함께 배치 파기.
--  · kind 는 v1 grooming 고정 — boarding(알림장)은 P2 에서 같은 원형을 반복형으로.
-- ============================================================================

-- (1) HMAC 키 싱글턴 — push_config 패턴. key_version 은 유출 시 무마이그레이션
--     로테이션용 선점(평시 단일 키, 0028 §10-3).
create table app.care_config (
  id          boolean primary key default true,
  hmac_key    text not null default encode(extensions.gen_random_bytes(32), 'hex'),
  key_version smallint not null default 1,
  constraint care_config_singleton check (id)
);
alter table app.care_config enable row level security; -- 정책 없음 = definer 전용
insert into app.care_config (id) values (true) on conflict (id) do nothing;

-- (2) 케어 리포트 (0028 §4.1)
create table app.care_reports (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.users(id) on delete cascade,
  kind          varchar(12) not null check (kind in ('grooming', 'boarding')),
  pet_label     varchar(50) not null,          -- 업체가 입력하는 아이 이름(미가입 보호자 전제)
  photos        jsonb not null default '[]',   -- [url, ...] — 미용은 전/후 2장 기본, 최대 4
  body          jsonb not null default '{}',   -- kind 별 확장 필드(boarding: 식사·배변 등, P2)
  note          text,
  recipient_phone_hmac  bytea,                 -- 수신 보호자 번호 키드 해시. claim 성사 시 null 파기
  recipient_key_version smallint not null default 1,
  claimed_by    uuid references public.users(id),
  claimed_at    timestamptz,                   -- 첫 claim 후 잠금(재 claim 불가)
  created_at    timestamptz not null default now()
);
create index care_reports_business_idx on app.care_reports (business_id, created_at desc);
create index care_reports_phone_idx on app.care_reports (recipient_phone_hmac)
  where claimed_by is null and recipient_phone_hmac is not null;
create index care_reports_claimed_idx on app.care_reports (claimed_by, created_at desc);
comment on table app.care_reports is
  '업체→보호자 케어 리포트(0028 §4 — 미용 전후 사진·P2 알림장 공용 원형).';

-- 전화번호 정규화 + HMAC — 숫자만 남겨 10~11자리 검증(형식 불일치는 null 반환).
create or replace function app.phone_hmac(p_phone text)
returns bytea
language plpgsql stable
set search_path to ''
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_key text;
begin
  if length(v_digits) not between 10 and 11 then return null; end if;
  select hmac_key into v_key from app.care_config;
  return extensions.hmac(v_digits, v_key, 'sha256');
end;
$$;

-- (3) 발행 — has_license('grooming') 게이트(0028 §1.3). 반환: 리포트 id + 공유 토큰.
create or replace function public.create_care_report(
  p_pet_label text,
  p_photos jsonb,
  p_note text default null,
  p_recipient_phone text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_label text := nullif(btrim(coalesce(p_pet_label, '')), '');
  v_hmac bytea;
  v_report uuid;
  v_token varchar(32);
  v_exp timestamptz;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not app.has_license('grooming') then
    raise exception 'license_required' using errcode = 'P0001';
  end if;
  if v_label is null or length(v_label) > 50 then
    raise exception 'invalid_pet_label' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_photos) is distinct from 'array'
     or jsonb_array_length(p_photos) not between 1 and 4 then
    raise exception 'invalid_photos' using errcode = 'P0001';
  end if;
  -- 전화번호는 선택 — 입력했는데 형식이 틀리면 자동 연결이 조용히 죽으므로 명시 거부.
  if p_recipient_phone is not null and btrim(p_recipient_phone) <> '' then
    v_hmac := app.phone_hmac(p_recipient_phone);
    if v_hmac is null then
      raise exception 'invalid_phone' using errcode = 'P0001';
    end if;
  end if;

  insert into app.care_reports
    (business_id, kind, pet_label, photos, note,
     recipient_phone_hmac, recipient_key_version)
  values
    (v_uid, 'grooming', v_label, p_photos, nullif(btrim(coalesce(p_note, '')), ''),
     v_hmac, (select key_version from app.care_config))
  returning id into v_report;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp := now() + interval '30 days';
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'care_report', v_report, v_uid, v_exp);

  insert into app.funnel_events (event, token, user_id)
  values ('report_issued', v_token, v_uid);

  return jsonb_build_object('report_id', v_report, 'token', v_token, 'expires_at', v_exp);
end;
$function$;
revoke all on function public.create_care_report(text, jsonb, text, text) from public;
grant execute on function public.create_care_report(text, jsonb, text, text) to authenticated;

-- (4) 내 발행 목록 — 수령자 연결 표시(오연결을 업체가 발견, 0028 §4.2-3).
create or replace function public.my_care_reports(
  p_limit integer default 30,
  p_offset integer default 0
) returns table (
  id uuid, pet_label text, photos jsonb, note text, created_at timestamptz,
  claimed_nickname text, token text, expires_at timestamptz, view_count integer
)
language sql stable security definer
set search_path to ''
as $$
  select r.id, r.pet_label::text, r.photos, r.note, r.created_at,
         pr.nickname::text, l.token::text, l.expires_at, l.view_count
    from app.care_reports r
    left join app.share_links l on l.kind = 'care_report' and l.ref_id = r.id
    left join public.public_profiles pr on pr.id = r.claimed_by
   where r.business_id = app.uid()
   order by r.created_at desc
   limit least(coalesce(p_limit, 30), 100) offset coalesce(p_offset, 0);
$$;
revoke all on function public.my_care_reports(integer, integer) from public;
grant execute on function public.my_care_reports(integer, integer) to authenticated;

-- (5) 자동 연결 — 가입 직후·앱 시작 시 호출. 내 인증 번호의 HMAC 와 일치하는
--     미연결 리포트를 연결하고 hmac 즉시 파기, 알림 발송. 연결 건수 반환.
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

  for r in
    update app.care_reports cr
       set claimed_by = v_uid, claimed_at = now(), recipient_phone_hmac = null
     where cr.recipient_phone_hmac = v_hmac
       and cr.claimed_by is null
       and cr.business_id <> v_uid          -- 자기 발행분 자기 연결 방지
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
  return v_cnt;
end;
$function$;
revoke all on function public.claim_care_reports() from public;
grant execute on function public.claim_care_reports() to authenticated;

-- (6) 내가 받은 리포트 목록 — 보호자 화면용.
create or replace function public.my_received_care_reports(
  p_limit integer default 30,
  p_offset integer default 0
) returns table (
  id uuid, kind text, pet_label text, photos jsonb, note text,
  created_at timestamptz, business_name text
)
language sql stable security definer
set search_path to ''
as $$
  select r.id, r.kind::text, r.pet_label::text, r.photos, r.note, r.created_at,
         coalesce(b.storefront_name, b.business_name)::text
    from app.care_reports r
    left join public.business_profiles b on b.user_id = r.business_id
   where r.claimed_by = app.uid()
   order by r.created_at desc
   limit least(coalesce(p_limit, 30), 100) offset coalesce(p_offset, 0);
$$;
revoke all on function public.my_received_care_reports(integer, integer) from public;
grant execute on function public.my_received_care_reports(integer, integer) to authenticated;

-- (7) 공유 뷰어 — care_report 분기 실장(기존 '준비 중' 스텁 대체).
--     미연결분 hmac 파기는 링크 만료와 동기(0028 3차 개정): 만료 리포트의 hmac
--     을 funnel 크론이 도는 시간대에 함께 정리하도록 여기서 처리하지 않고,
--     별도 크론에 위임(아래 (8)).
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
        'kind', r.kind, 'created_at', r.created_at,
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

-- (8) 미연결 리포트의 hmac 파기 — 링크 만료(30일) 경과분(0028 §4.2-4).
--     funnel 보존 크론과 같은 시간대(03:53대) 뒤인 03:58 에 별도 잡.
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
                      and l.expires_at < now())$$);
