-- 승인 업체 정보 수정 + 지도(facilities) 동기화 (0025 후속 — 업체 프로필 분리 2차).
-- 승인된 업체가 사업장명(간판명)·업장 전화·연락 이메일을 수정하면, 매칭된 시설
-- 행(지도 마커·상세)에 간판명·전화가 즉시 반영된다.
--
-- 주의: facilities 는 월 1회 LOCALDATA 재적재(upsert)가 소유자 수정분을 덮어쓸 수
-- 있다 → owner_updated_at 을 스탬프해 두고, 재적재 절차(0021·0025 §8)는 이 값이
-- 있는 행의 name/phone 을 보존해야 한다(재적재 스크립트 규칙에 반영할 것).
-- 사업자번호·주소·업종 변경은 심사 근거가 바뀌는 것이라 수정 불가 — 재신청 경로만.

alter table public.facilities add column if not exists owner_updated_at timestamptz;

create or replace function public.update_my_business_info(
  p_storefront_name text default null,
  p_phone           text default null,
  p_email           text default null
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_name text := nullif(btrim(coalesce(p_storefront_name, '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_email text := nullif(btrim(coalesce(p_email, '')), '');
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    storefront_name = coalesce(v_name, storefront_name),
    business_phone  = coalesce(v_phone, business_phone),
    contact_email   = coalesce(v_email, contact_email),
    updated_at = now()
  where user_id = v_me;

  -- 지도 동기화 — 매칭 시설의 간판명·전화만(주소·업종·영업상태는 인허가 데이터 영역)
  if v_row.matched_facility_id is not null and (v_name is not null or v_phone is not null) then
    update public.facilities set
      name = coalesce(v_name, name),
      phone = coalesce(v_phone, phone),
      owner_updated_at = now(),
      updated_at = now()
    where id = v_row.matched_facility_id;
  end if;
end;
$function$;

revoke all on function public.update_my_business_info(text,text,text) from public, anon;
grant execute on function public.update_my_business_info(text,text,text) to authenticated;
