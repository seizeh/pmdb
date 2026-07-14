-- 업체(사업자) 계정 — 코어 스키마 (0025 §2·§3.3·§4).
-- business_profiles(1:1) + business_match_rules(무마이그레이션 튜닝) + users.active_mode
-- + 비공개 business-docs 버킷 + 정규화 함수/trgm 인덱스 + notifications CHECK 확장
-- + public_profiles 에 is_business/business_name 노출 + 서류 파기 큐.

-- 0) 상호·주소 정규화 (0025 §4.3 명세).
--    표현식 GIN 인덱스에 쓰이므로 IMMUTABLE 필수. 순서: 법인표기 → 괄호쌍 → 소문자 → 특수문자.
create or replace function app.norm_biz_text(t text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(
           lower(
             regexp_replace(
               regexp_replace(coalesce(t, ''),
                 '주식회사|유한회사|유한책임회사|합자회사|합명회사|\(주\)|㈜|\(유\)|\(합\)', '', 'g'),
               '\([^)]*\)', '', 'g')
           ),
           '[^0-9a-z가-힣]', '', 'g')
$$;

-- 대조용 trgm 인덱스 (pg_trgm 은 extensions 스키마에 설치되어 있음 — v1.6, 게시글 검색용).
create index if not exists facilities_norm_name_trgm_gix
  on public.facilities using gin (app.norm_biz_text((name)::text) extensions.gin_trgm_ops);

-- 1) 업체 프로필 (0025 §2.1)
create table public.business_profiles (
  user_id             uuid primary key references public.users(id) on delete cascade,
  business_reg_no     varchar(10) not null
                        check (business_reg_no ~ '^\d{10}$'),
  declared_category   varchar(20) not null
                        check (declared_category in
                          ('pet_sales','pet_hotel','animal_hospital','grooming','other')),
  business_name       text not null,
  storefront_name     text,
  prev_business_name  text,
  business_address    text not null,
  business_address_jibun text,
  business_region_code varchar(20),
  business_phone      varchar(40),
  representative_name text,
  contact_email       text not null
                        check (contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  license_image_path  text not null,
  extra_doc_path      text,
  nts_status_code     varchar(2),
  nts_checked_at      timestamptz,
  matched_facility_id uuid references public.facilities(id) on delete set null,
  matched_biz_key     text,
  match_score         integer,
  match_detail        jsonb,
  review_track        varchar not null default 'review'
                        check (review_track in ('auto','review','new_business')),
  auto_approved       boolean not null default false,
  review_note         text,
  status              varchar not null default 'pending'
                        check (status in ('pending','approved','rejected')),
  rejected_reason     text,
  reviewed_by         uuid references public.users(id),
  reviewed_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table public.business_profiles is
  '업체(사업자) 인증 프로필 — users 와 1:1, 쓰기는 definer RPC 전용 (0025).';

-- 부분 유니크: pending/approved 만 점유 — 반려 건이 번호·업소를 영구 점유하지 않게 (0025 §2.2)
create unique index business_profiles_regno_active_uq
  on public.business_profiles (business_reg_no)
  where status in ('pending','approved');

-- 실존 업소 1곳 = 활성 계정 1개. 행이 아니라 물리 업소 키(biz_key) 기준 —
-- 겸업 업소의 카테고리 행 바꿔치기 우회 차단 (0025 §1.5-5)
create unique index business_profiles_bizkey_active_uq
  on public.business_profiles (matched_biz_key)
  where matched_biz_key is not null and status in ('pending','approved');

-- RLS: 본인 행 SELECT 만. INSERT/UPDATE 정책 없음 = definer RPC 전용 (status/match_* 위조 차단)
alter table public.business_profiles enable row level security;
grant select on public.business_profiles to authenticated;
create policy business_profiles_select_own on public.business_profiles
  for select to authenticated using (user_id = app.uid());

-- 2) 매칭 규칙 — 배점·임계값·스위치 (0025 §2.5). 조정은 admin_set_match_rule 로(무마이그레이션).
--    주의: 필수 AND(전화·업종)는 로직이므로 이 테이블로 끌 수 없음. enabled=false 는 배점에만 영향.
create table public.business_match_rules (
  rule_key   varchar primary key,
  weight     integer not null,
  enabled    boolean not null default true,
  params     jsonb,
  note       text,
  updated_at timestamptz not null default now()
);

alter table public.business_match_rules enable row level security;
grant select on public.business_match_rules to authenticated;
create policy business_match_rules_admin_select on public.business_match_rules
  for select to authenticated using (app.is_admin());

insert into public.business_match_rules (rule_key, weight, enabled, params, note) values
  ('phone_exact',          35, true,  null,              '업장 전화 정규화 완전일치(자동승인 필수 AND 겸용)'),
  ('name_high',            30, true,  '{"sim":0.85}',    '상호 유사도 상위(현 상호·사업장명·이전 상호 중 max)'),
  ('name_mid',             20, true,  '{"sim":0.60}',    '상호 유사도 중위 — 후보 검색 하한 겸용'),
  ('addr_region',          10, true,  null,              '행정코드 시군구(5자리) 일치'),
  ('addr_sim',             10, false, '{"sim":0.70}',    '지번-대-지번 유사도 — 표기 형식 표본 검증 전까지 OFF(0025 §1.5-3)'),
  ('category_match',       15, true,  null,              '업종 일치(자동승인 필수 AND 겸용)'),
  ('threshold_auto',       80, true,  null,              '자동승인 임계값'),
  ('threshold_review',     50, true,  null,              '관리자검토/신규개업 경계'),
  ('auto_approve_enabled',  0, false, null,              '자동승인 운영 스위치 — enabled 가 스위치(0025 §1.6, 초기 OFF)');

-- 3) 계정 전환 모드 (0025 §2.3)
alter table public.users add column if not exists active_mode varchar not null default 'personal'
  check (active_mode in ('personal','business'));

-- 4) 알림 타입 확장 (+business_approved/business_rejected — 누락 시 알림이 조용히 안 생김)
alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (notification_type in (
    'chat_message','post_application','post_comment','pawing_new_post',
    'application_accepted','application_accepted_by_co','review_received',
    'guardian_invite','system_notice','location_expired','chat_read_receipt',
    'unread_sync','security_login','schedule_changed',
    'business_approved','business_rejected'
  ));

-- 5) 자동승인은 시스템 행위라 admin_id 가 없다 — 감사로그 기록을 위해 nullable 로 완화
--    (콘솔 표시는 null → '시스템'으로).
alter table public.admin_logs alter column admin_id drop not null;

-- 6) 비공개 서류 버킷 (0025 §3.3) — 열람은 signed URL 로만
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-docs','business-docs', false, 10485760,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy "business docs owner insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'business-docs' and (storage.foldername(name))[1] = app.uid()::text);
create policy "business docs owner select" on storage.objects for select to authenticated
  using (bucket_id = 'business-docs' and (storage.foldername(name))[1] = app.uid()::text);
create policy "business docs admin select" on storage.objects for select to authenticated
  using (bucket_id = 'business-docs' and app.is_admin());

-- 7) 서류 파기 큐 (0025 §3.3 — 반려 6개월·탈퇴 30일·교체분 30일).
--    실제 파일 삭제는 storage API 가 필요해 SQL 크론으로 불가 → purge-business-docs 엣지가
--    due 행을 처리(§8 체크리스트). 처리 시 '현재 pending/approved 행이 참조 중인 경로'는 건너뛴다
--    (반려 후 같은 파일로 재신청한 케이스 보호).
create table app.business_doc_purge_queue (
  id          bigint generated always as identity primary key,
  path        text not null,
  reason      text not null,          -- 'rejected' | 'withdraw' | 'superseded'
  purge_after timestamptz not null,
  purged_at   timestamptz,
  created_at  timestamptz not null default now()
);
alter table app.business_doc_purge_queue enable row level security; -- 정책 없음 = definer 전용

-- 8) 공개 프로필에 업체 노출 (0025 §2.3 확정 정책):
--    is_business = approved 여부(모드 무관 — 신뢰 정보), business_name 은 business 모드일 때만.
create or replace view public.public_profiles as
  select u.id, u.nickname, u.user_type, u.profile_image_url, u.profile_image_thumbnail_url,
         u.address, u.is_location_verified, u.created_at, u.activity_radius_m,
         coalesce(bp.status = 'approved', false) as is_business,
         case when u.active_mode = 'business' and bp.status = 'approved'
              then bp.business_name end as business_name
    from public.users u
    left join public.business_profiles bp on bp.user_id = u.id;
