-- 관리자 RPC 5종 감사 기록 — "누가 했는지"가 남지 않던 마지막 관리자 행위들
-- (v9.2 알려진 결함: 감사 미기록 admin RPC 5종)
--
-- 정지·숨김 등 다른 관리자 행위는 admin_logs 원장에 남는데, 이 5종은 예외였다.
-- 특히 QR 회수(admin_revoke_share_link)는 revoked_at 만 찍혀 **행위자가 시스템
-- 어디에도 없었다**(발급은 share_links.created_by 로 부분 귀속). 관리자가 1인인
-- 지금은 실피해가 없지만, 관리자가 늘어나는 순간 소급이 불가능한 부류다.
--
-- 방침 두 가지:
-- ① 상태가 실제로 바뀐 경우에만 기록한다 — 발급의 기존 링크 재사용 반환,
--    join 의 중복 재진입(on conflict)은 변경이 없으므로 기록하지 않는다(노이즈 방지).
-- ② 원장에 토큰 원문을 싣지 않는다 — 토큰은 capability 라 원장이 두 번째 토큰
--    저장소가 되면 안 된다. 대조용 접두 8자만 남긴다(kind+ref_id 로 행 특정 가능).

alter table app.share_links add column revoked_by uuid;
comment on column app.share_links.revoked_by is
  '회수한 관리자(app.uid()) — 2026-09-21 신설. 그 이전 회수 행은 NULL(행위자 미상)';

-- 1) 시설 폐업/해제 판정
create or replace function public.admin_mark_facility_closed(p_facility uuid, p_closed boolean DEFAULT true)
returns void
language plpgsql security definer set search_path to ''
as $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.facilities
     set reported_closed_at = case when p_closed then now() else null end,
         -- 해제 시에는 원천 상태(biz_status)로 되돌린다 — 임의로 true 를 넣지 않는다.
         is_open = case when p_closed then false
                        else (coalesce(biz_status, '') ~ '영업|정상') end,
         updated_at = now()
   where id = p_facility;
  if not found then
    raise exception 'facility_not_found' using errcode = 'P0001';
  end if;
  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'facility_mark_closed', 'facility', p_facility,
          jsonb_build_object('closed', p_closed));
end $$;

-- 2) 시설 미리보기 공유 링크(QR) 발급
create or replace function public.admin_create_facility_share_link(p_facility uuid, p_days integer DEFAULT 365)
returns table(token character varying, expires_at timestamp with time zone)
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_token varchar(32);
  v_exp   timestamptz;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_days < 1 or p_days > 3650 then
    raise exception 'days 1..3650';
  end if;
  if not exists (select 1 from public.facilities f where f.id = p_facility) then
    raise exception 'facility not found';
  end if;

  select l.token, l.expires_at into v_token, v_exp
  from app.share_links l
  where l.kind = 'facility_preview' and l.ref_id = p_facility
    and l.revoked_at is null and l.expires_at > now()
  order by l.created_at desc limit 1;
  if v_token is not null then
    -- 재사용 반환 — 상태 변경 없음, 감사 기록 없음
    return query select v_token, v_exp;
    return;
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp   := now() + make_interval(days => p_days);
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'facility_preview', p_facility, app.uid(), v_exp);
  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'share_link_create', 'facility', p_facility,
          jsonb_build_object('kind', 'facility_preview',
                             'token_prefix', left(v_token, 8),
                             'expires_at', v_exp));
  return query select v_token, v_exp;
end;
$$;

-- 3) 분양 스타터 공유 링크(QR) 발급
create or replace function public.admin_create_starter_share_link(p_business uuid, p_days integer DEFAULT 365)
returns table(token character varying, expires_at timestamp with time zone)
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_token varchar(32);
  v_exp   timestamptz;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_days < 1 or p_days > 3650 then
    raise exception 'days 1..3650';
  end if;
  -- 발급 명단 = 승인 업체 + 판매/생산 허가 승인(0028 §1.3)
  if not exists (select 1 from public.business_profiles b
                  where b.user_id = p_business and b.status = 'approved') then
    raise exception 'business_not_approved';
  end if;
  if not exists (select 1 from app.business_licenses l
                  where l.user_id = p_business
                    and l.license_type in ('sales', 'production')
                    and l.status = 'approved') then
    raise exception 'starter_license_required';
  end if;

  -- 유효(미회수·미만료) 링크 재사용
  select l.token, l.expires_at into v_token, v_exp
  from app.share_links l
  where l.kind = 'starter' and l.ref_id = p_business
    and l.revoked_at is null and l.expires_at > now()
  order by l.created_at desc limit 1;
  if v_token is not null then
    -- 재사용 반환 — 상태 변경 없음, 감사 기록 없음
    return query select v_token, v_exp;
    return;
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_exp   := now() + make_interval(days => p_days);
  insert into app.share_links (token, kind, ref_id, created_by, expires_at)
  values (v_token, 'starter', p_business, app.uid(), v_exp);
  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'share_link_create', 'user', p_business,
          jsonb_build_object('kind', 'starter',
                             'token_prefix', left(v_token, 8),
                             'expires_at', v_exp));
  return query select v_token, v_exp;
end;
$$;

-- 4) 공유 링크(QR) 회수 — 행위자 무기록이 가장 아팠던 곳
create or replace function public.admin_revoke_share_link(p_token character varying)
returns boolean
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_kind   varchar(30);
  v_ref_id uuid;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update app.share_links
     set revoked_at = now(),
         revoked_by = app.uid()
   where token = p_token and revoked_at is null
  returning kind, ref_id into v_kind, v_ref_id;
  if not found then
    return false;
  end if;
  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'share_link_revoke',
          case when v_kind = 'starter' then 'user' else 'facility' end, v_ref_id,
          jsonb_build_object('kind', v_kind, 'token_prefix', left(p_token, 8)));
  return true;
end;
$$;

-- 5) 고객센터 문의 개입
create or replace function public.admin_join_inquiry(p_room uuid)
returns void
language plpgsql security definer set search_path to ''
as $$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists (select 1 from public.chat_rooms where id=p_room and room_type='admin_inquiry') then
    raise exception 'not_inquiry_room' using errcode='P0001';
  end if;
  insert into public.chat_room_members(room_id, user_id)
  values (p_room, app.uid())
  on conflict (room_id, user_id) do nothing;
  if found then
    -- 실제로 새로 참여한 경우에만 — 중복 재진입은 상태 변경이 없다
    insert into public.admin_logs (admin_id, action_type, target_type, target_id)
    values (app.uid(), 'inquiry_join', 'chat_room', p_room);
  end if;
end;
$$;
