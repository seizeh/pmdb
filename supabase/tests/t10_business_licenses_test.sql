-- 업종 모듈 권한(0028 §1) — business_licenses 신청/승인/게이트/재신청 불변식.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(11);

-- 추가 시드: 관리자(심사자).
create temp table t10 (k text primary key, id uuid not null);
with u as (
  insert into public.users
    (username, password_hash, nickname, user_type, phone, status, active_mode)
  values ('t_admin', 'x', '시드관리자', 'admin', '01000000009', 'active', 'personal')
  returning id
)
insert into t10 select 'admin', id from u;

-- ① 승인 업체가 아닌 개인은 신청 불가.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);
select throws_like(
  $$select public.apply_business_license('grooming', 'A-1234',
      (select id::text || '/licenses/g.png' from seed where k='owner'))$$,
  '%biz_profile_required%',
  '업체 인증 없이 업종 증빙 신청 불가'
);

-- ② 승인 업체(bizowner)는 신청 성공 — pending.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select lives_ok(
  $$select public.apply_business_license('grooming', 'A-1234',
      (select id::text || '/licenses/g.png' from seed where k='bizowner'))$$,
  '승인 업체의 업종 증빙 신청 성공'
);

-- ③ pending 상태에선 게이트 닫힘.
select is(
  app.has_license('grooming'),
  false,
  'pending 은 has_license=false'
);

-- ④ 타인 폴더 서류 경로는 거부.
select throws_like(
  $$select public.apply_business_license('boarding', 'B-5678',
      (select id::text || '/licenses/steal.png' from seed where k='owner'))$$,
  '%invalid_document_path%',
  '타인 폴더 서류 경로 거부'
);

-- ⑤ 관리자 승인 → 게이트 열림.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t10 where k='admin'), 'tv', 0)::text, true);
select lives_ok(
  $$select public.admin_review_business_license(
      (select l.id from app.business_licenses l
        where l.user_id = (select id from seed where k='bizowner')
          and l.license_type = 'grooming'),
      'approved')$$,
  '관리자 승인 성공'
);
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select is(
  app.has_license('grooming'),
  true,
  '승인 후 has_license=true'
);

-- ⑥ 반려(사유 필수) → 서류 파기 큐 적재.
select lives_ok(
  $$select public.apply_business_license('boarding', 'B-5678',
      (select id::text || '/licenses/b.png' from seed where k='bizowner'))$$,
  '두 번째 업종(boarding) 신청 성공'
);
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t10 where k='admin'), 'tv', 0)::text, true);
select public.admin_review_business_license(
  (select l.id from app.business_licenses l
    where l.user_id = (select id from seed where k='bizowner')
      and l.license_type = 'boarding'),
  'rejected', '허가번호 불일치');
select is(
  (select count(*)::int from app.business_doc_purge_queue
    where path = (select id::text || '/licenses/b.png' from seed where k='bizowner')),
  1,
  '반려 서류 파기 큐 적재'
);

-- ⑦(계속) 재신청 — rejected → pending 복귀 + 같은 서류 재제출 시 큐에서 회수.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='bizowner'), 'tv', 0)::text, true);
select public.apply_business_license('boarding', 'B-5678',
  (select id::text || '/licenses/b.png' from seed where k='bizowner'));
select is(
  (select l.status || ':' || (select count(*)::int from app.business_doc_purge_queue
      where path = l.document_path)::text
     from app.business_licenses l
    where l.user_id = (select id from seed where k='bizowner')
      and l.license_type = 'boarding'),
  'pending:0',
  '재신청 시 pending 복귀 + 파기 큐 회수'
);

-- ⑧ 업체 등록과 동시 신청 — pending 업체도 신청 가능(등록 폼 동시 제출).
insert into public.business_profiles
  (user_id, business_reg_no, declared_category, business_name,
   business_address, contact_email, license_image_path, status)
select id, '9999999999', 'grooming', '동시신청테스트',
       '서울 어딘가 1', 'p@test.co', 'x/p.png', 'pending'
  from seed where k = 'friend';
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='friend'), 'tv', 0)::text, true);
select lives_ok(
  $$select public.apply_business_license('grooming', 'C-9999',
      (select id::text || '/licenses/c.png' from seed where k='friend'))$$,
  'pending 업체의 동시 신청 허용'
);

-- ⑨ 단, 업종 '승인'은 업체 인증 승인이 선행돼야 한다(순서 보장).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t10 where k='admin'), 'tv', 0)::text, true);
select throws_like(
  $$select public.admin_review_business_license(
      (select l.id from app.business_licenses l
        where l.user_id = (select id from seed where k='friend')
          and l.license_type = 'grooming'),
      'approved')$$,
  '%business_not_approved%',
  '업체 미승인 상태의 업종 승인 차단'
);

select * from finish();
rollback;
