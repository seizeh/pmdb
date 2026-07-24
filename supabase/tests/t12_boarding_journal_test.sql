-- 위탁 알림장(0028 P2) — 스레드 모델·반복 발행·스레드 claim·보관 파생 불변식.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(14);

create temp table t12 (k text primary key, id uuid not null);

-- ① boarding 라이선스 없는 업체는 스레드 생성 불가.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select throws_like(
  $$select public.create_care_thread('구름')$$,
  '%license_required%',
  'boarding 라이선스 없이 스레드 생성 불가'
);

-- 추가 시드: boarding 승인 라이선스.
insert into app.business_licenses (user_id, license_type, license_no, document_path, status)
select id, 'boarding', 'T-2222', id::text || '/l.png', 'approved'
  from seed where k = 'bizowner';

-- ② 스레드 생성(수신자 = friend 번호, 선택 입력).
with t as (
  select public.create_care_thread('구름', '010-0000-0002') as id
)
insert into t12 select 'th', id from t;
select is(
  (select count(*)::int from app.care_threads
    where id = (select id from t12 where k='th')),
  1,
  '스레드 생성 성공'
);

-- ③ 알림장 발행 — 사진+식사·배변 body.
select lives_ok(
  $$select public.create_boarding_report(
      (select id from t12 where k='th'),
      '["b1.jpg"]'::jsonb,
      '{"meal":"사료 잘 먹음","potty":"정상"}'::jsonb,
      '오늘 산책도 신나게 했어요')$$,
  '알림장 발행 성공'
);
select is(
  (select count(*)::int from app.share_links l
    join app.care_reports r on r.id = l.ref_id
   where l.kind = 'care_report' and r.thread_id = (select id from t12 where k='th')),
  1,
  '발행마다 단건 공유 링크 생성'
);

-- ④ 전부 빈 발행은 거부.
select throws_like(
  $$select public.create_boarding_report((select id from t12 where k='th'))$$,
  '%empty_report%',
  '빈 알림장 거부'
);

-- ⑤ friend claim → 스레드 연결 + 기존 기록도 함께 연결.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select is(public.claim_care_reports(), 1, '스레드 자동 연결 1건');
select is(
  (select bool_and(r.claimed_by = (select id from seed where k='friend'))
     from app.care_reports r
    where r.thread_id = (select id from t12 where k='th')),
  true,
  '기존 기록도 연결됨'
);

-- ⑥ 연결 후 발행 — 기록 즉시 연결 + 도착 알림.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select lives_ok(
  $$select public.create_boarding_report(
      (select id from t12 where k='th'), '["b2.jpg"]'::jsonb)$$,
  '연결 후 발행 성공'
);
select is(
  (select count(*)::int from public.notifications
    where user_id = (select id from seed where k='friend')
      and title = '구름 돌봄 기록이 도착했어요'),
  1,
  '연결 보호자에게 도착 알림'
);

-- ⑦ 보호자는 스레드 기록 조회 가능.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select is(
  (select count(*)::int from public.care_thread_reports((select id from t12 where k='th'))),
  2,
  '연결 보호자 스레드 기록 조회'
);

-- ⑧ 제3자는 접근 불가.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);
select throws_like(
  $$select * from public.care_thread_reports((select id from t12 where k='th'))$$,
  '%thread_not_found%',
  '제3자 스레드 접근 거부'
);

-- ⑨ 받은 기록에 알림장 포함(thread_id 노출).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select is(
  (select count(*)::int from public.my_received_care_reports()
    where kind = 'boarding' and thread_id = (select id from t12 where k='th')),
  2,
  '받은 기록에 알림장 포함'
);

-- ⑩ 보관은 파생값 — 마지막 발행을 임계(7일) 밖으로 밀면 archived=true,
--    새 기록이 오면(위 ⑥ 이후 상태) false 였음을 함께 확인.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select is(
  (select archived from public.my_care_threads()
    where id = (select id from t12 where k='th')),
  false,
  '최근 발행 스레드는 활성'
);
update app.care_threads set last_report_at = now() - interval '8 days'
 where id = (select id from t12 where k='th');
select is(
  (select archived from public.my_care_threads()
    where id = (select id from t12 where k='th')),
  true,
  '무입력 7일 경과 → 보관(파생)'
);

select * from finish();
rollback;
