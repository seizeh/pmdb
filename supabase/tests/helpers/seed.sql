-- 공용 시드 — 각 테스트의 트랜잭션 안에서 \ir 로 포함된다(테스트 종료 시 롤백).
-- 참조는 temp table seed(k → id) 로 넘긴다.
--
--  owner      : 개인·동네인증 유효 (pet_owner, 펫 1마리 보유)
--  friend     : 개인·동네인증 유효
--  unverified : 개인·동네인증 없음 (게이트 테스트용)
--  bizowner   : 업체 모드·개인 동네인증 없음 + 승인 업체(business_profiles)

create temp table seed (k text primary key, id uuid not null);

with u as (
  insert into public.users
    (username, password_hash, nickname, user_type, phone, status, active_mode,
     region_code, address, is_location_verified, last_verified_at)
  values
    ('t_owner', 'x', '시드주인', 'pet_owner', '01000000001', 'active', 'personal',
     '1111010100', '서울 종로구 청운동', true, now())
  returning id
)
insert into seed select 'owner', id from u;

with u as (
  insert into public.users
    (username, password_hash, nickname, user_type, phone, status, active_mode,
     region_code, address, is_location_verified, last_verified_at)
  values
    ('t_friend', 'x', '시드친구', 'no_pet', '01000000002', 'active', 'personal',
     '1111010100', '서울 종로구 청운동', true, now())
  returning id
)
insert into seed select 'friend', id from u;

with u as (
  insert into public.users
    (username, password_hash, nickname, user_type, phone, status, active_mode)
  values
    ('t_unverified', 'x', '시드미인증', 'no_pet', '01000000004', 'active', 'personal')
  returning id
)
insert into seed select 'unverified', id from u;

with u as (
  insert into public.users
    (username, password_hash, nickname, user_type, phone, status, active_mode)
  values
    ('t_biz', 'x', '시드사장', 'no_pet', '01000000003', 'active', 'business')
  returning id
)
insert into seed select 'bizowner', id from u;

-- 승인 업체 — 사업장 지역코드 보유(소식 글 지역 스탬프 검증용).
insert into public.business_profiles
  (user_id, business_reg_no, declared_category, business_name,
   business_address, business_region_code, contact_email, license_image_path, status)
select id, '1234567890', 'other', '테스트업체',
       '경기도 테스트시 테스트동 1', '4100000000', 't@test.co', 'x/license.png', 'approved'
  from seed where k = 'bizowner';

-- owner 의 펫 1마리 — pets AFTER INSERT 트리거가 pet_guardians(owner) 자동 등록.
with p as (
  insert into public.pets (primary_guardian_id, name, species)
  select id, '시드펫', '믹스' from seed where k = 'owner'
  returning id
)
insert into seed select 'pet1', id from p;

-- 케어 설정 싱글턴 — **CI 에서만 없는 행**이라 여기서 보장한다.
--
-- dump_schema.sh 는 구조만 덤프하므로(데이터 제외) CI 컨테이너의 app.care_config
-- 는 0행이다. 그러면 app.phone_hmac 의 `select hmac_key into v_key` 가 NULL 을
-- 집어 extensions.hmac(digits, NULL, 'sha256') 이 NULL 을 돌려주고,
-- create_care_report 가 번호를 못 읽었다며 invalid_phone 을 던진다
-- (t11 단언 2·3·4·6·7·8 실패, t12 는 아예 SQL 오류로 중단).
-- 운영 DB 직행 검증에서는 행이 이미 있어 통과하므로 CI 에서만 드러났다.
--
-- hmac_key 는 컬럼 기본값(랜덤 32바이트)에 맡긴다 — 테스트는 같은 트랜잭션 안에서
-- 발행·조회를 모두 하므로 키 값 자체는 무관하고, 운영 키를 흉내 낼 이유도 없다.
-- 이미 행이 있으면(운영 직행 검증) 아무것도 하지 않는다.
insert into app.care_config (id)
select true where not exists (select 1 from app.care_config);
