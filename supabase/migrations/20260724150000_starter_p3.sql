-- ============================================================================
-- 0028 P3 — 분양 스타터: 스타터 QR 랜딩 · 접종 일정 알림
--
-- 분양업체는 입점 파트너가 아니라 **가입 유통 채널**(0028 원칙 4) — 앱 안에
-- 분양업체용 기능·노출은 만들지 않고, 새 보호자에게 스타터 패키지(접종 알림·
-- 체크리스트·동네 지도)를 QR 랜딩으로 전달한다(§5).
--  · 스타터 QR: kind='starter' 공유 링크(ref = 업체 계정) — 업체별 고유 토큰으로
--    스캔→열람→스토어 클릭이 매장별로 계측된다(§7). 발급은 관리자 운영 도구
--    (sales/production 허가 승인 업체 명단 대상, §1.3 — 인앱 모듈은 열지 않음).
--  · 접종 알림: 표준 접종 일정(항목·날짜 계산은 앱 콘텐츠)을 이벤트로 저장하고,
--    매일 아침 크론이 D-1·당일분을 펫 보호자 전원에게 알림(0027 파이프라인).
--    리마인더일 뿐 수의학적 판단은 담지 않는다. 이벤트당 알림은 1회
--    (notified_at 잠금), 등록 시점에 이미 지난 일정은 조용히 소화한다.
-- ============================================================================

-- (1) share_links kind 확장 — 'starter'
alter table app.share_links drop constraint share_links_kind_check;
alter table app.share_links add constraint share_links_kind_check
  check (kind in ('facility_preview', 'care_report', 'starter'));

-- (2) 스타터 QR 발급 — 관리자 전용. facility 링크와 같은 재사용 원칙
--     (업체당 QR 1장, 재호출로 기존 인쇄물이 무효화되지 않게).
create or replace function public.admin_create_starter_share_link(
  p_business uuid,
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
  -- 발급 명단 = 승인 업체 + 판매/생산 허가 승인(0028 §1.3)
  if not exists (select 1 from public.business_profiles b
                  where b.user_id = p_business and b.status = 'approved') then
    raise exception 'business_not_approved';
  end if;
  if not exists (select 1 from app.business_licenses l
                  where l.user_id = p_business
                    and l.license_type in ('sales', 'production')
                    and l.status = 'approved') then
    raise exception 'starter_license_required';
  end if;

  -- 유효(미회수·미만료) 링크 재사용
  select l.token, l.expires_at into v_token, v_exp
  from app.share_links l
  where l.kind = 'starter' and l.ref_id = p_business
    and l.revoked_at is null and l.expires_at > now()
  order by l.created_at desc limit 1;
  if v_token is not null then
    return query select v_token, v_exp;
    return;
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp   := now() + make_interval(days => p_days);
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'starter', p_business, app.uid(), v_exp);
  return query select v_token, v_exp;
end;
$function$;
revoke all on function public.admin_create_starter_share_link(uuid, integer) from public;
grant execute on function public.admin_create_starter_share_link(uuid, integer) to authenticated;

-- (3) 뷰어 — starter 분기 추가(업체명만 — 랜딩 본문은 정적 콘텐츠, Edge Function)
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

  if v_link.kind = 'starter' then
    select jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'starter', jsonb_build_object(
        'business_name', coalesce(b.storefront_name, b.business_name)))
    into v_out
    from public.business_profiles b
    where b.user_id = v_link.ref_id and b.status = 'approved';
    -- 업체가 인증 취소돼도 랜딩 자체는 살아있게(출처 표기만 생략)
    return coalesce(v_out, jsonb_build_object(
      'status', 'ok', 'kind', v_link.kind,
      'starter', jsonb_build_object('business_name', null)));
  end if;

  return jsonb_build_object('status', 'ok', 'kind', v_link.kind);
end;
$function$;

-- (4) 접종 일정 이벤트 — 앱이 계산한 표준 일정(라벨+날짜)을 저장만 한다.
create table app.vaccination_events (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets(id) on delete cascade,
  label       varchar(60) not null,          -- '종합백신 2차' 등(앱 콘텐츠)
  due_date    date not null,
  done_at     timestamptz,                   -- 보호자 완료 체크
  notified_at timestamptz,                   -- 발송 1회 잠금
  created_by  uuid not null references public.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index vaccination_events_pet_idx on app.vaccination_events (pet_id, due_date);
create index vaccination_events_due_idx on app.vaccination_events (due_date)
  where done_at is null and notified_at is null;
comment on table app.vaccination_events is
  '분양 스타터 접종 리마인더(0028 §5) — 일정 콘텐츠는 앱, 서버는 저장·알림만.';

-- (5) 일정 저장 — 보호자(pet_guardians) 전용. 미완료분을 통째로 교체한다
--     (완료 체크된 이벤트는 기록으로 보존). p_source 는 퍼널 계측용
--     ('onboarding' = 가입 분기, 'manage' = 펫 화면).
create or replace function public.set_vaccination_schedule(
  p_pet uuid,
  p_events jsonb,
  p_source text default null
) returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_cnt integer := 0;
  e jsonb;
  v_label text;
  v_due date;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pet_guardians g
                 where g.pet_id = p_pet and g.user_id = v_uid) then
    raise exception 'not_guardian' using errcode = 'P0001';
  end if;
  if jsonb_typeof(coalesce(p_events, '[]'::jsonb)) is distinct from 'array'
     or jsonb_array_length(coalesce(p_events, '[]'::jsonb)) > 40 then
    raise exception 'invalid_events' using errcode = 'P0001';
  end if;
  if p_source is not null and p_source not in ('onboarding', 'manage') then
    raise exception 'invalid_source' using errcode = 'P0001';
  end if;

  delete from app.vaccination_events
   where pet_id = p_pet and done_at is null;

  for e in select value from jsonb_array_elements(coalesce(p_events, '[]'::jsonb))
  loop
    v_label := nullif(btrim(coalesce(e->>'label', '')), '');
    if v_label is null or length(v_label) > 60
       or coalesce(e->>'due_date', '') !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'invalid_events' using errcode = 'P0001';
    end if;
    v_due := (e->>'due_date')::date;
    if v_due not between current_date - 730 and current_date + 1095 then
      raise exception 'invalid_events' using errcode = 'P0001';
    end if;
    insert into app.vaccination_events (pet_id, label, due_date, created_by)
    values (p_pet, v_label, v_due, v_uid);
    v_cnt := v_cnt + 1;
  end loop;

  insert into app.funnel_events (event, user_id, props)
  values ('vaccine_schedule', v_uid,
          jsonb_build_object('pet_id', p_pet, 'count', v_cnt,
                             'source', p_source));
  return v_cnt;
end;
$function$;
revoke all on function public.set_vaccination_schedule(uuid, jsonb, text) from public;
grant execute on function public.set_vaccination_schedule(uuid, jsonb, text) to authenticated;

-- (6) 일정 조회 — 보호자 전용, 날짜순.
create or replace function public.my_vaccination_events(p_pet uuid)
returns table (id uuid, label text, due_date date, done_at timestamptz)
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pet_guardians g
                 where g.pet_id = p_pet and g.user_id = v_uid) then
    raise exception 'not_guardian' using errcode = 'P0001';
  end if;
  return query
  select e.id, e.label::text, e.due_date, e.done_at
    from app.vaccination_events e
   where e.pet_id = p_pet
   order by e.due_date, e.created_at;
end;
$function$;
revoke all on function public.my_vaccination_events(uuid) from public;
grant execute on function public.my_vaccination_events(uuid) to authenticated;

-- (7) 완료 체크 토글 — 보호자 전용.
create or replace function public.set_vaccination_done(
  p_event uuid,
  p_done boolean default true
) returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  update app.vaccination_events e
     set done_at = case when p_done then now() else null end
   where e.id = p_event
     and exists (select 1 from public.pet_guardians g
                 where g.pet_id = e.pet_id and g.user_id = v_uid);
  return found;
end;
$function$;
revoke all on function public.set_vaccination_done(uuid, boolean) from public;
grant execute on function public.set_vaccination_done(uuid, boolean) to authenticated;

-- (8) 알림 타입·리소스 확장 — vaccine_reminder / resource 'pet'
alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (((notification_type)::text = any (array[
    'chat_message'::text, 'post_application'::text, 'post_comment'::text,
    'pawing_new_post'::text, 'application_accepted'::text,
    'application_accepted_by_co'::text, 'review_received'::text,
    'guardian_invite'::text, 'system_notice'::text, 'location_expired'::text,
    'chat_read_receipt'::text, 'unread_sync'::text, 'security_login'::text,
    'schedule_changed'::text, 'business_approved'::text, 'business_rejected'::text,
    'review_comment'::text, 'post_heart'::text, 'pawing_follow'::text,
    'facility_review_received'::text, 'pet_in_post'::text, 'vaccine_reminder'::text])));

alter table public.notifications drop constraint notifications_resource_type_check;
alter table public.notifications add constraint notifications_resource_type_check
  check (((resource_type is null) or ((resource_type)::text = any (array[
    'post'::text, 'comment'::text, 'chat_room'::text, 'appointment'::text,
    'facility_review'::text, 'user'::text, 'pet'::text]))));

-- (9) 접종 리마인더 크론 — 매일 09:00 KST(00:00 UTC). D-1·당일분을 보호자
--     전원에게 1회 알림. 등록 시점에 이미 지난 일정은 notified_at 만 찍고
--     알림 없이 소화한다(뒤늦은 등록이 알림 폭탄이 되지 않게).
do $$ begin
  if exists (select 1 from cron.job where jobname = 'vaccine-reminder-sweep') then
    perform cron.unschedule('vaccine-reminder-sweep');
  end if;
end $$;
select cron.schedule('vaccine-reminder-sweep', '0 0 * * *',
  $$with due as (
      update app.vaccination_events e
         set notified_at = now()
       where e.done_at is null and e.notified_at is null
         and e.due_date <= (now() at time zone 'Asia/Seoul')::date + 1
      returning e.pet_id, e.label, e.due_date
    )
    insert into public.notifications
      (user_id, notification_type, is_system, title, body, resource_type, resource_id)
    select g.user_id, 'vaccine_reminder', true,
           p.name || ' 접종일이 다가와요',
           d.label || ' — ' ||
           case when d.due_date <= (now() at time zone 'Asia/Seoul')::date
                then '오늘' else '내일' end || ' 예정이에요. 병원 일정을 확인해 주세요.',
           'pet', d.pet_id
      from due d
      join public.pets p on p.id = d.pet_id and p.pet_status = 'active'
      join public.pet_guardians g on g.pet_id = d.pet_id
     where d.due_date >= (now() at time zone 'Asia/Seoul')::date$$);
