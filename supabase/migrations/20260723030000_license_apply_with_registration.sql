-- ============================================================================
-- 업종 인증을 업체 등록과 한 번에 신청 (0028 §1 보완)
--
-- 기존: 업체 인증 '승인' 후에만 업종 인증 신청 가능 → 사장님이 서류·심사·대기를
-- 두 번 겪는다(파일럿 온보딩 이탈 포인트). 신청 게이트를 pending 까지 완화해
-- 업체 등록 폼에서 등록·허가증을 함께 제출할 수 있게 한다.
--
-- 순서 보장은 승인 쪽으로 이동: 업종 인증 '승인'은 업체 인증이 approved 일 때만
-- (business_not_approved). 반려는 순서 무관. 서류 정합(무허가 차단)은 그대로.
-- ============================================================================

-- (1) 신청 게이트 완화 — pending 업체도 신청 가능(rejected 는 업체 재신청과 함께)
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
  -- 업체 등록과 동시 신청 허용 — pending 포함(승인 순서는 심사 RPC 가 보장).
  if not exists (select 1 from public.business_profiles b
                 where b.user_id = v_uid and b.status in ('pending', 'approved')) then
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
  if v_path is null or position(v_uid::text || '/' in v_path) <> 1 then
    raise exception 'invalid_document_path' using errcode = 'P0001';
  end if;

  select * into v_old from app.business_licenses
   where user_id = v_uid and license_type = v_type;
  if found and v_old.status = 'approved' then
    raise exception 'already_approved' using errcode = 'P0001';
  end if;

  delete from app.business_doc_purge_queue where path = v_path;
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

-- (2) 승인 순서 보장 — 업체 인증 미승인 상태의 업종 인증 '승인' 차단
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
  -- 동시 신청 허용의 대가: 업종 승인은 업체 인증 승인이 선행돼야 한다.
  if p_status = 'approved' and not exists (
    select 1 from public.business_profiles b
    where b.user_id = v_row.user_id and b.status = 'approved'
  ) then
    raise exception 'business_not_approved' using errcode = 'P0001';
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
