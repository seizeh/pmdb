-- 계정 모드별 행동 격리 (양방향)
--
-- 정책: 업체 모드에선 '개인 계정 활동'(매칭: 지원·수락/거절·약속·평가)에 관여
-- 불가, 개인 모드에선 '업체 계정 활동'(업체 정보·대표 사진 수정) 불가.
-- 예외: 시설 후기 댓글은 진입 시 전환 선택을 제공하므로 모드 무관 허용.
-- 하트·댓글·팔로우·게시글 작성은 두 얼굴 공용이라 대상 아님.
--
-- 액터 기준(app.uid 의 active_mode) — 매칭 쓰기의 주체는 항상 본인이다
-- (자기 지원, 자기가 수락, 자기가 평가 작성). 트리거는 최종 방어선이고
-- 클라이언트는 해당 버튼을 숨긴다.

create or replace function app.assert_personal_actor()
returns void
language plpgsql stable security definer set search_path to ''
as $$
begin
  if (select u.active_mode from public.users u where u.id = app.uid()) = 'business' then
    raise exception 'business_mode_not_allowed' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function app.assert_business_actor()
returns void
language plpgsql stable security definer set search_path to ''
as $$
begin
  if coalesce(
       (select u.active_mode from public.users u where u.id = app.uid()),
       'personal') <> 'business' then
    raise exception 'business_mode_required' using errcode = 'P0001';
  end if;
end;
$$;

-- ── 개인 전용 매칭 쓰기 차단(업체 모드 액터) ────────────────────────────
create or replace function app.tg_block_business_actor()
returns trigger
language plpgsql security definer set search_path to ''
as $$
begin
  perform app.assert_personal_actor();
  return case tg_op when 'DELETE' then old else new end;
end;
$$;

-- 지원 수락/거절/취소 등 상태 변경(INSERT 는 기존 applications_block_business_mode 유지)
drop trigger if exists trg_applications_block_business_update on public.applications;
create trigger trg_applications_block_business_update
  before update on public.applications
  for each row execute function app.tg_block_business_actor();

-- 약속 생성·일정 변경 (수락 시 definer 트리거가 만드는 경우도 액터=수락자(개인)라 통과)
drop trigger if exists trg_appointments_block_business on public.appointments;
create trigger trg_appointments_block_business
  before insert or update on public.appointments
  for each row execute function app.tg_block_business_actor();

-- 매칭 상대 평가 작성
drop trigger if exists trg_reviews_block_business on public.reviews;
create trigger trg_reviews_block_business
  before insert on public.reviews
  for each row execute function app.tg_block_business_actor();

-- ── 업체 전용 쓰기 차단(개인 모드 액터) — 기존 RPC 에 모드 게이트 추가 ──
-- 대표 사진 설정.
create or replace function public.set_my_business_photo(
  p_url text default null, p_align_y real default 0)
returns void
language plpgsql security definer set search_path to ''
as $$
declare
  v_me uuid := app.uid();
  v_row public.business_profiles%rowtype;
  v_align real := greatest(-1, least(1, coalesce(p_align_y, 0)));
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  perform app.assert_business_actor();
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    photo_url = p_url, photo_align_y = v_align, updated_at = now()
  where user_id = v_me;

  if v_row.matched_facility_id is not null then
    update public.facilities set
      owner_photo_url = p_url, owner_photo_align_y = v_align,
      owner_updated_at = now(), updated_at = now()
    where id = v_row.matched_facility_id;
  end if;
end;
$$;

-- 업체 정보 수정(간판명·전화·이메일·영업시간).
create or replace function public.update_my_business_info(
  p_storefront_name text default null,
  p_phone text default null,
  p_email text default null,
  p_hours text default null
) returns void
language plpgsql security definer set search_path to ''
as $$
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
  perform app.assert_business_actor();
  select * into v_row from public.business_profiles where user_id = v_me;
  if not found or v_row.status <> 'approved' then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;
  if length(coalesce(p_hours, '')) > 100 then
    raise exception 'hours_too_long' using errcode = 'P0001';
  end if;

  update public.business_profiles set
    storefront_name = coalesce(v_name, storefront_name),
    business_phone  = coalesce(v_phone, business_phone),
    contact_email   = coalesce(v_email, contact_email),
    business_hours  = case when p_hours is null then business_hours
                           else nullif(btrim(p_hours), '') end,
    updated_at = now()
  where user_id = v_me;

  if v_row.matched_facility_id is not null
     and (v_name is not null or v_phone is not null or p_hours is not null) then
    update public.facilities set
      name = coalesce(v_name, name),
      phone = coalesce(v_phone, phone),
      business_hours = case when p_hours is null then business_hours
                            else nullif(btrim(p_hours), '') end,
      owner_updated_at = now(),
      updated_at = now()
    where id = any(public.facility_sibling_ids(v_row.matched_facility_id));
  end if;
end;
$$;
