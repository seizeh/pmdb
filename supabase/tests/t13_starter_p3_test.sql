-- 분양 스타터(0028 P3) — 스타터 QR 발급 게이트·랜딩 데이터·접종 일정·리마인더 스윕.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(17);

create temp table t13 (k text primary key, id uuid not null);

-- 추가 시드: 관리자.
with u as (
  insert into public.users
    (username, password_hash, nickname, user_type, phone, status, active_mode)
  values ('t_admin', 'x', '시드관리자', 'admin', '01000000009', 'active', 'personal')
  returning id
)
insert into t13 select 'admin', id from u;

-- ① 관리자 아니면 스타터 링크 발급 불가.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select throws_like(
  $$select * from public.admin_create_starter_share_link(
      (select id from seed where k='bizowner'))$$,
  '%forbidden%',
  '비관리자 스타터 링크 발급 거부'
);

-- ② 판매/생산 허가 승인 없는 업체는 발급 대상 아님.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t13 where k='admin'), 'tv', 0)::text, true);
select throws_like(
  $$select * from public.admin_create_starter_share_link(
      (select id from seed where k='bizowner'))$$,
  '%starter_license_required%',
  'sales/production 허가 없는 업체 발급 거부'
);

-- 추가 시드: sales 허가 승인.
insert into app.business_licenses (user_id, license_type, license_no, document_path, status)
select id, 'sales', 'T-3333', id::text || '/l.png', 'approved'
  from seed where k = 'bizowner';

-- ③ 발급 성공(32자 hex 토큰).
select lives_ok(
  $$select * from public.admin_create_starter_share_link(
      (select id from seed where k='bizowner'))$$,
  '스타터 링크 발급 성공'
);
select is(
  (select count(*)::int from app.share_links
    where kind = 'starter' and ref_id = (select id from seed where k='bizowner')
      and token ~ '^[0-9a-f]{32}$'),
  1,
  '스타터 링크 발급 성공'
);

-- ④ 재호출은 같은 토큰 재사용(인쇄물 보호).
select is(
  (select count(distinct l.token)::int
     from public.admin_create_starter_share_link(
       (select id from seed where k='bizowner')) l
     join app.share_links s on s.token = l.token
    where s.kind = 'starter'),
  1,
  '유효 링크 재사용'
);
select is(
  (select count(*)::int from app.share_links
    where kind = 'starter' and ref_id = (select id from seed where k='bizowner')),
  1,
  '재호출로 링크가 늘지 않음'
);

-- ⑤ 뷰어 로드 — kind/업체명 반환.
select is(
  (select public.share_view_load(
     (select token from app.share_links
       where kind = 'starter'
         and ref_id = (select id from seed where k='bizowner')))
   #>> '{starter,business_name}'),
  '테스트업체',
  '스타터 랜딩 데이터(업체명)'
);

-- ⑥ 접종 일정 — 보호자 아니면 저장 불가.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select throws_like(
  $$select public.set_vaccination_schedule(
      (select id from seed where k='pet1'),
      '[{"label":"종합백신 1차","due_date":"2026-08-01"}]'::jsonb)$$,
  '%not_guardian%',
  '비보호자 일정 저장 거부'
);

-- ⑦ 보호자 저장 성공(3건) + 퍼널 계측.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);
select is(
  public.set_vaccination_schedule(
    (select id from seed where k='pet1'),
    jsonb_build_array(
      jsonb_build_object('label', '종합백신 1차', 'due_date', to_char(current_date + 1, 'YYYY-MM-DD')),
      jsonb_build_object('label', '종합백신 2차', 'due_date', to_char(current_date + 15, 'YYYY-MM-DD')),
      jsonb_build_object('label', '광견병', 'due_date', to_char(current_date + 60, 'YYYY-MM-DD'))),
    'onboarding'),
  3,
  '접종 일정 저장(3건)'
);
select is(
  (select count(*)::int from app.funnel_events
    where event = 'vaccine_schedule'
      and user_id = (select id from seed where k='owner')
      and props->>'source' = 'onboarding'),
  1,
  '일정 저장 퍼널 계측'
);

-- ⑧ 형식 오류는 명시 거부.
select throws_like(
  $$select public.set_vaccination_schedule(
      (select id from seed where k='pet1'),
      '[{"label":"x","due_date":"내일"}]'::jsonb)$$,
  '%invalid_events%',
  '잘못된 날짜 형식 거부'
);

-- ⑨ 완료 체크 후 재저장 — 완료분은 보존, 미완료분만 교체.
select ok(
  public.set_vaccination_done(
    (select id from app.vaccination_events
      where pet_id = (select id from seed where k='pet1')
        and label = '종합백신 1차')),
  '완료 체크'
);
select is(
  public.set_vaccination_schedule(
    (select id from seed where k='pet1'),
    jsonb_build_array(
      jsonb_build_object('label', '켄넬코프 1차', 'due_date', to_char(current_date + 30, 'YYYY-MM-DD'))),
    'manage'),
  1,
  '재저장(미완료 교체)'
);
select is(
  (select count(*)::int from app.vaccination_events
    where pet_id = (select id from seed where k='pet1')),
  2,
  '완료 1건 보존 + 신규 1건'
);

-- ⑩ 조회는 보호자 전용, 날짜순 전체 반환.
select is(
  (select count(*)::int from public.my_vaccination_events(
     (select id from seed where k='pet1'))),
  2,
  '보호자 일정 조회'
);

-- ⑪ 리마인더 스윕(크론 본문과 동일 SQL) — D-1 이내 미완료분을 보호자에게 1회 알림.
update app.vaccination_events
   set due_date = current_date
 where pet_id = (select id from seed where k='pet1') and done_at is null;
with due as (
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
 where d.due_date >= (now() at time zone 'Asia/Seoul')::date;
select is(
  (select count(*)::int from public.notifications
    where notification_type = 'vaccine_reminder'
      and user_id = (select id from seed where k='owner')
      and resource_type = 'pet'
      and resource_id = (select id from seed where k='pet1')),
  1,
  '접종 리마인더 알림 생성(CHECK 통과 포함)'
);

-- ⑫ 스윕 재실행 — notified_at 잠금으로 중복 알림 없음.
with due as (
  update app.vaccination_events e
     set notified_at = now()
   where e.done_at is null and e.notified_at is null
     and e.due_date <= (now() at time zone 'Asia/Seoul')::date + 1
  returning e.pet_id, e.label, e.due_date
)
insert into public.notifications
  (user_id, notification_type, is_system, title, body, resource_type, resource_id)
select g.user_id, 'vaccine_reminder', true, 'x', 'x', 'pet', d.pet_id
  from due d
  join public.pet_guardians g on g.pet_id = d.pet_id;
select is(
  (select count(*)::int from public.notifications
    where notification_type = 'vaccine_reminder'
      and user_id = (select id from seed where k='owner')),
  1,
  '스윕 재실행 시 중복 알림 없음'
);

select * from finish();
rollback;
