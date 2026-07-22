-- ============================================================================
-- 0028 §1 — 업종 모듈 권한: business_licenses (계정당 업종별 증빙 1행)
--
-- 0025 의 business_profiles 는 사업자(계정) 단위 인증 — 그 아래 업종 단위 증빙
-- 층을 추가한다. 기능 게이트의 진실의 원천은 이 테이블의 approved 행 존재 여부
-- (app.has_license)이고, business_category 는 파생 표시값으로 강등(0028 §1.4).
--
-- 동물보호법: 등록제(미용·위탁관리·전시·운송) / 허가제(생산·판매·수입·장묘).
-- 자동승인 없음 — 업종 증빙은 문서 위조 리스크 대비 건수가 적어 관리자 수동
-- 검토가 싸다(0028 §1.2). 서류는 business-docs 비공개 버킷(기존 정책 재사용:
-- 소유자 업로드/조회 + 관리자 조회), 반려 시 6개월 후 파기 큐(0025 §3.3 편입).
-- 알림은 기존 business_approved/rejected 타입 재사용(CHECK 변경 없음).
-- ============================================================================

create type app.biz_license_type as enum (
  'grooming',      -- 동물미용업 (등록제) → 전후 사진 모듈
  'boarding',      -- 동물위탁관리업 (등록제) → 알림장 모듈
  'sales',         -- 동물판매업 (허가제) → 인앱 모듈 없음(스타터 QR 채널)
  'production',    -- 동물생산업 (허가제) → 〃
  'exhibition',    -- 동물전시업 (등록제) — 당장 모듈 없음, enum 선점
  'transport'      -- 동물운송업 (등록제) — 〃
);

create table app.business_licenses (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users(id) on delete cascade,
  license_type  app.biz_license_type not null,
  license_no    varchar(40) not null,        -- 지자체 등록·허가번호(형식 자유)
  document_path text not null,               -- 등록·허가증 사본(business-docs 버킷)
  status        varchar(12) not null default 'pending'
                check (status in ('pending', 'approved', 'rejected')),
  reject_reason text,
  reviewed_by   uuid references public.users(id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, license_type)             -- 계정당 업종별 1행(재신청은 갱신)
);
comment on table app.business_licenses is
  '업종별 등록·허가 증빙(0028 §1). approved 행 존재 = 해당 업종 모듈 ON(app.has_license).';

create trigger trg_business_licenses_updated
  before update on app.business_licenses
  for each row execute function app.tg_set_updated_at();

-- ── 모듈 게이트 — 도구 RPC 첫 줄에서 호출(클라이언트 직접 호출 경로 없음:
--    app 스키마는 클라이언트 롤에 USAGE 가 없다) ──
create or replace function app.has_license(p_type app.biz_license_type)
returns boolean
language sql stable security definer
set search_path to ''
as $$
  select exists (
    select 1 from app.business_licenses
    where user_id = app.uid() and license_type = p_type and status = 'approved'
  );
$$;

-- ── 신청/재신청 (본인) ──
-- 전제: business_profiles 승인 완료(사업자 인증 없이 업종 증빙만 낼 수 없음).
-- 재신청: rejected 행은 pending 으로 갱신, approved 행은 already_approved 거부,
-- pending 행은 서류·번호 교체 허용. 교체로 버려지는 이전 서류는 파기 큐(1개월).
create or replace function public.apply_business_license(
  p_type text,
  p_license_no text,
  p_document_path text
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid  uuid := app.uid();
  v_type app.biz_license_type;
  v_no   text := nullif(btrim(coalesce(p_license_no, '')), '');
  v_path text := nullif(btrim(coalesce(p_document_path, '')), '');
  v_old  app.business_licenses%rowtype;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'auth required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.business_profiles b
                 where b.user_id = v_uid and b.status = 'approved') then
    raise exception 'biz_profile_required' using errcode = 'P0001';
  end if;
  begin
    v_type := p_type::app.biz_license_type;
  exception when others then
    raise exception 'invalid_type' using errcode = 'P0001';
  end;
  if v_no is null or length(v_no) < 4 or length(v_no) > 40 then
    raise exception 'invalid_license_no' using errcode = 'P0001';
  end if;
  -- 서류는 본인 폴더(business-docs 버킷, uid/ 프리픽스)만 — 타인 경로 참조 차단.
  if v_path is null or position(v_uid::text || '/' in v_path) <> 1 then
    raise exception 'invalid_document_path' using errcode = 'P0001';
  end if;

  select * into v_old from app.business_licenses
   where user_id = v_uid and license_type = v_type;
  if found and v_old.status = 'approved' then
    raise exception 'already_approved' using errcode = 'P0001';
  end if;

  -- 재제출한 서류가 반려 파기 큐에 있으면 회수(0025 재신청 패턴).
  delete from app.business_doc_purge_queue where path = v_path;
  -- 교체로 버려지는 이전 서류는 1개월 후 파기.
  if found and v_old.document_path <> v_path then
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_old.document_path, 'replaced', now() + interval '1 month');
  end if;

  insert into app.business_licenses (user_id, license_type, license_no, document_path)
  values (v_uid, v_type, v_no, v_path)
  on conflict (user_id, license_type) do update
    set license_no = excluded.license_no,
        document_path = excluded.document_path,
        status = 'pending', reject_reason = null,
        reviewed_by = null, reviewed_at = null, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$function$;
revoke all on function public.apply_business_license(text, text, text) from public;
grant execute on function public.apply_business_license(text, text, text) to authenticated;

-- ── 내 라이선스 목록 (본인) — 업체 관리 패널 표시용 ──
create or replace function public.my_business_licenses()
returns table (
  id uuid, license_type text, license_no text, status text,
  reject_reason text, created_at timestamptz, reviewed_at timestamptz
)
language sql stable security definer
set search_path to ''
as $$
  select l.id, l.license_type::text, l.license_no::text, l.status::text,
         l.reject_reason, l.created_at, l.reviewed_at
    from app.business_licenses l
   where l.user_id = app.uid()
   order by l.created_at;
$$;
revoke all on function public.my_business_licenses() from public;
grant execute on function public.my_business_licenses() to authenticated;

-- ── 관리자: 심사 목록 ──
create or replace function public.admin_list_business_licenses(
  p_status text default 'pending',
  p_limit integer default 50,
  p_offset integer default 0
) returns table (
  id uuid, user_id uuid, nickname text, business_name text,
  license_type text, license_no text, document_path text,
  status text, reject_reason text, created_at timestamptz, reviewed_at timestamptz
)
language plpgsql stable security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select l.id, l.user_id, u.nickname::text, b.business_name::text,
         l.license_type::text, l.license_no::text, l.document_path,
         l.status::text, l.reject_reason, l.created_at, l.reviewed_at
    from app.business_licenses l
    join public.users u on u.id = l.user_id
    left join public.business_profiles b on b.user_id = l.user_id
   where (p_status is null or l.status = p_status)
   order by l.created_at
   limit least(coalesce(p_limit, 50), 200) offset coalesce(p_offset, 0);
end;
$function$;
revoke all on function public.admin_list_business_licenses(text, integer, integer) from public;
grant execute on function public.admin_list_business_licenses(text, integer, integer) to authenticated;

-- ── 관리자: 승인/반려 (admin_set_business_status 패턴) ──
create or replace function public.admin_review_business_license(
  p_license uuid,
  p_status text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_row app.business_licenses%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_label text;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  select * into v_row from app.business_licenses where id = p_license;
  if not found then
    raise exception 'license_not_found' using errcode = 'P0001';
  end if;
  if v_row.status = p_status then
    raise exception 'no_change' using errcode = 'P0001';
  end if;

  v_label := case v_row.license_type
    when 'grooming' then '동물미용업' when 'boarding' then '동물위탁관리업'
    when 'sales' then '동물판매업' when 'production' then '동물생산업'
    when 'exhibition' then '동물전시업' when 'transport' then '동물운송업'
  end;

  if p_status = 'rejected' then
    if v_reason is null then
      raise exception 'reason_required' using errcode = 'P0001';
    end if;
    update app.business_licenses set
      status = 'rejected', reject_reason = v_reason,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where id = p_license;

    -- 서류 6개월(재신청 유예) 후 파기 — 재신청 시 apply 가 큐에서 회수.
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_row.document_path, 'license_rejected', now() + interval '6 months');

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_row.user_id, 'business_rejected', true,
            v_label || ' 인증이 반려되었어요',
            '사유: ' || v_reason || E'\n업체 관리에서 보완 후 다시 신청할 수 있어요.');
  else
    update app.business_licenses set
      status = 'approved', reject_reason = null,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where id = p_license;

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (v_row.user_id, 'business_approved', true,
            v_label || ' 인증이 완료되었어요',
            v_label || ' 인증이 승인되었어요. 해당 업종 기능이 열렸어요.');
  end if;

  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'review_business_license', 'user', v_row.user_id,
          jsonb_build_object('license_id', p_license, 'type', v_row.license_type,
                             'from', v_row.status, 'to', p_status, 'reason', v_reason));
end;
$function$;
revoke all on function public.admin_review_business_license(uuid, text, text) from public;
grant execute on function public.admin_review_business_license(uuid, text, text) to authenticated;
