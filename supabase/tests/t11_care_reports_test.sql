-- 케어 리포트(0028 P1) — 라이선스 게이트·발행·전화번호 HMAC 자동 연결 불변식.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(9);

-- ① 업종 라이선스(grooming) 없는 업체는 발행 불가.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select throws_like(
  $$select public.create_care_report('초코', '["u1.jpg","u2.jpg"]'::jsonb)$$,
  '%license_required%',
  'grooming 라이선스 없이 발행 불가'
);

-- 추가 시드: grooming 승인 라이선스(게이트 통과용 직접 삽입).
insert into app.business_licenses (user_id, license_type, license_no, document_path, status)
select id, 'grooming', 'T-1111', id::text || '/l.png', 'approved'
  from seed where k = 'bizowner';

-- ② 발행 성공 — 수신자 번호는 friend(01000000002, 선택 입력).
select lives_ok(
  $$select public.create_care_report('초코', '["u1.jpg","u2.jpg"]'::jsonb,
      '오늘 컷 예쁘게 됐어요', '010-0000-0002')$$,
  '발행 성공(전화번호 선택 입력 포함)'
);

-- ③ 공유 링크(care_report)와 발행 계측이 생성된다.
select is(
  (select count(*)::int from app.share_links l
    join app.care_reports r on r.id = l.ref_id
   where l.kind = 'care_report'
     and r.business_id = (select id from seed where k='bizowner')),
  1,
  '공유 링크 생성'
);
select is(
  (select count(*)::int from app.funnel_events where event = 'report_issued'),
  1,
  '발행 퍼널 이벤트 기록'
);

-- ④ 형식이 틀린 번호는 명시 거부(자동 연결이 조용히 죽지 않게).
select throws_like(
  $$select public.create_care_report('보리', '["u3.jpg"]'::jsonb, null, '1234')$$,
  '%invalid_phone%',
  '잘못된 번호 형식 거부'
);

-- ⑤ friend 가 로그인해 claim → 자동 연결 1건.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select is(public.claim_care_reports(), 1, '전화번호 대조 자동 연결 1건');

-- ⑥ 연결 결과 — claimed_by = friend, hmac 즉시 파기.
select is(
  (select (r.claimed_by = (select id from seed where k='friend'))
          and r.recipient_phone_hmac is null
     from app.care_reports r
    where r.business_id = (select id from seed where k='bizowner')
      and r.pet_label = '초코'),
  true,
  'claimed_by 연결 + hmac 파기'
);

-- ⑦ 도착 알림 발송.
select is(
  (select count(*)::int from public.notifications
    where user_id = (select id from seed where k='friend')
      and title like '초코%도착했어요'),
  1,
  '도착 알림 발송'
);

-- ⑧ 재호출은 0건(첫 claim 후 잠금).
select is(public.claim_care_reports(), 0, '재claim 0건(잠금)');

select * from finish();
rollback;
