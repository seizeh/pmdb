-- 공동보호자 초대 불변식 — 자기 자신 초대는 어떤 경로로도 불가(트리거 백스톱),
-- 가입 번호 초대는 invitee 가 즉시 연결된다.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(3);

-- ① 자기 자신 초대(본인 전화번호) → 트리거가 거부.
select throws_like(
  $$insert into public.pet_guardian_invites (pet_id, kind, inviter_id, invitee_phone)
    select (select id from seed where k='pet1'), 'invite',
           (select id from seed where k='owner'), '01000000001'$$,
  '%self_invite%',
  '자기 자신 공동보호자 초대는 거부된다'
);

-- ② 타인(가입자) 초대는 성공.
select lives_ok(
  $$insert into public.pet_guardian_invites (pet_id, kind, inviter_id, invitee_phone)
    select (select id from seed where k='pet1'), 'invite',
           (select id from seed where k='owner'), '01000000002'$$,
  '가입자 번호 초대 성공'
);

-- ③ 가입 번호는 발송 시점에 invitee_user_id 로 즉시 연결(resolve 트리거).
select is(
  (select invitee_user_id from public.pet_guardian_invites
    where inviter_id = (select id from seed where k='owner') limit 1),
  (select id from seed where k='friend'),
  '가입자 초대는 invitee_user_id 즉시 연결'
);

select * from finish();
rollback;
