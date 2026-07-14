-- 업체 승인 관리자 RPC + 규칙 튜닝 RPC + 탈퇴 연동 (0025 §6·§2.2·§3.3).
-- 패턴: is_admin 게이트 SECURITY DEFINER + admin_logs 감사(admin_users_rpcs 컨벤션).

-- 1) 신청 목록 (0025 §6) — 서류는 경로만 반환, 열람은 콘솔이 signed URL 발급(비공개 버킷)
create or replace function public.admin_list_business_applications(
  p_status    text default 'pending',
  p_track     text default null,
  p_auto_only boolean default false,
  p_limit     int default 50,
  p_offset    int default 0
)
returns table (
  user_id uuid, nickname text, business_reg_no text, declared_category text,
  business_name text, storefront_name text, prev_business_name text,
  business_address text, business_address_jibun text, business_phone text,
  representative_name text, contact_email text,
  license_image_path text, extra_doc_path text,
  nts_status_code text, nts_checked_at timestamptz,
  matched_facility_id uuid, matched_facility_name text, matched_biz_key text,
  match_score int, match_detail jsonb, review_track text, auto_approved boolean,
  status text, rejected_reason text, review_note text,
  reviewed_by uuid, reviewed_at timestamptz, created_at timestamptz, updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('pending','approved','rejected') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  if p_track is not null and p_track not in ('auto','review','new_business') then
    raise exception 'invalid_track' using errcode = 'P0001';
  end if;
  return query
  select bp.user_id, u.nickname::text, bp.business_reg_no::text, bp.declared_category::text,
         bp.business_name, bp.storefront_name, bp.prev_business_name,
         bp.business_address, bp.business_address_jibun, bp.business_phone::text,
         bp.representative_name, bp.contact_email,
         bp.license_image_path, bp.extra_doc_path,
         bp.nts_status_code::text, bp.nts_checked_at,
         bp.matched_facility_id, f.name::text, bp.matched_biz_key,
         bp.match_score, bp.match_detail, bp.review_track::text, bp.auto_approved,
         bp.status::text, bp.rejected_reason, bp.review_note,
         bp.reviewed_by, bp.reviewed_at, bp.created_at, bp.updated_at
    from public.business_profiles bp
    join public.users u on u.id = bp.user_id
    left join public.facilities f on f.id = bp.matched_facility_id
   where (p_status is null or bp.status = p_status)
     and (p_track is null or bp.review_track = p_track)
     and (not p_auto_only or bp.auto_approved)
   order by bp.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 100))
  offset greatest(0, coalesce(p_offset, 0));
end;
$function$;

grant execute on function public.admin_list_business_applications(text,text,boolean,int,int) to authenticated;

-- 2) 승인/반려 (0025 §6).
--    - 반려: 사유 필수. active_mode 강제 복귀 + 서류 6개월 파기 큐 + 알림.
--    - 승인: track='auto' 대기 건(스위치 OFF 운영)은 일반 승인. 그 외(review/new_business)는
--      자동승인 조건 미달의 override — 사유 필수, review_note 저장, 감사로그 별도 action.
create or replace function public.admin_set_business_status(
  p_user   uuid,
  p_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_row public.business_profiles%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_override boolean;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;

  select * into v_row from public.business_profiles where user_id = p_user;
  if not found then
    raise exception 'application_not_found' using errcode = 'P0001';
  end if;
  if v_row.status = p_status then
    raise exception 'no_change' using errcode = 'P0001';
  end if;

  if p_status = 'rejected' then
    if v_reason is null then
      raise exception 'reason_required' using errcode = 'P0001';
    end if;

    update public.business_profiles set
      status = 'rejected', rejected_reason = v_reason,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where user_id = p_user;

    -- 전환 자격 상실 → personal 강제 복귀 (0025 §2.3)
    update public.users set active_mode = 'personal'
     where id = p_user and active_mode = 'business';

    -- 서류 6개월(재신청 유예) 후 파기 — 재신청 시 apply RPC 가 큐에서 제거 (0025 §3.3)
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    select p, 'rejected', now() + interval '6 months'
      from unnest(array_remove(array[v_row.license_image_path, v_row.extra_doc_path], null)) p;

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (p_user, 'business_rejected', true, '업체 인증이 반려되었어요',
            '사유: ' || v_reason || E'\n내정보 수정에서 보완 후 다시 신청할 수 있어요.');

    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(), 'set_business_status', 'user', p_user,
            jsonb_build_object('from', v_row.status, 'to', 'rejected', 'reason', v_reason));
  else
    -- 승인. review/new_business 트랙은 자동승인 조건 미달의 override — 사유 필수 (0025 §6-2)
    v_override := v_row.review_track <> 'auto';
    if v_override and v_reason is null then
      raise exception 'override_reason_required' using errcode = 'P0001';
    end if;

    update public.business_profiles set
      status = 'approved', rejected_reason = null,
      review_note = case when v_override then v_reason else review_note end,
      reviewed_by = app.uid(), reviewed_at = now(), updated_at = now()
    where user_id = p_user;

    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (p_user, 'business_approved', true, '업체 인증이 완료되었어요',
            '업체 인증이 승인되었어요. 내정보 수정에서 업체 모드로 전환할 수 있어요.');

    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (app.uid(),
            case when v_override then 'business_override_approved' else 'set_business_status' end,
            'user', p_user,
            jsonb_build_object('from', v_row.status, 'to', 'approved',
                               'track', v_row.review_track, 'score', v_row.match_score,
                               'override', v_override, 'reason', v_reason));
  end if;
end;
$function$;

grant execute on function public.admin_set_business_status(uuid,text,text) to authenticated;

-- 3) 매칭 규칙 튜닝 (0025 §2.5) — 배점·임계값·스위치 무마이그레이션 조정 + 감사로그
create or replace function public.admin_set_match_rule(
  p_key     text,
  p_weight  int default null,
  p_enabled boolean default null,
  p_params  jsonb default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare v_before public.business_match_rules%rowtype;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_before from public.business_match_rules where rule_key = p_key;
  if not found then
    raise exception 'rule_not_found' using errcode = 'P0001';
  end if;

  update public.business_match_rules set
    weight = coalesce(p_weight, weight),
    enabled = coalesce(p_enabled, enabled),
    params = coalesce(p_params, params),
    updated_at = now()
  where rule_key = p_key;

  insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
  values (app.uid(), 'set_business_match_rule', 'system', null,
          jsonb_build_object('rule_key', p_key,
            'before', jsonb_build_object('weight', v_before.weight, 'enabled', v_before.enabled, 'params', v_before.params),
            'after',  jsonb_build_object('weight', coalesce(p_weight, v_before.weight),
                                         'enabled', coalesce(p_enabled, v_before.enabled),
                                         'params', coalesce(p_params, v_before.params))));
end;
$function$;

grant execute on function public.admin_set_match_rule(text,int,boolean,jsonb) to authenticated;

-- 4) 파기 큐 처리 RPC (purge-business-docs 엣지 전용 — app 스키마는 PostgREST 미노출이라
--    service_role definer RPC 로만 접근). take: 재사용 파일 파기 취소 후 due 행 반환.
create or replace function public.business_doc_purge_take(p_limit int default 200)
returns table (id bigint, path text)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- 안전망: pending/approved 행이 참조 중인 경로는 파기 취소(반려 후 같은 파일로 재신청한 케이스)
  delete from app.business_doc_purge_queue q
   where q.purged_at is null
     and exists (select 1 from public.business_profiles bp
                  where bp.status in ('pending','approved')
                    and (bp.license_image_path = q.path or bp.extra_doc_path = q.path));
  return query
  select q.id, q.path
    from app.business_doc_purge_queue q
   where q.purged_at is null and q.purge_after <= now()
   order by q.id
   limit greatest(1, least(coalesce(p_limit, 200), 500));
end;
$function$;

create or replace function public.business_doc_purge_done(p_ids bigint[])
returns void
language sql
security definer
set search_path to ''
as $function$
  update app.business_doc_purge_queue
     set purged_at = now()
   where id = any(p_ids) and purged_at is null;
$function$;

revoke all on function public.business_doc_purge_take(int) from public, anon, authenticated;
revoke all on function public.business_doc_purge_done(bigint[]) from public, anon, authenticated;

-- 5) 탈퇴 연동 (0025 §2.2·§3.3) — 번호·업소 키 반납 + 서류 30일 파기 큐.
--    주의: 단순 status='rejected' 전환만으로는 30일/6개월 보존기간이 구분되지 않으므로
--    탈퇴 경로가 파기 큐에 직접(30일) 등록한다. 20260712041855 정의에 업체 블록만 추가.
create or replace function public.withdraw_account()
returns void language plpgsql security definer set search_path to '' as $function$
declare
  v_me uuid := app.uid();
  v_tag text;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  v_tag := substr(replace(v_me::text, '-', ''), 1, 10);

  -- 부정이용 방지 분리보관 (아이디·전화번호, 30일 후 cron 파기)
  insert into app.withdrawn_users (user_id, username, phone)
  select u.id, u.username, u.phone from public.users u where u.id = v_me
  on conflict (user_id) do nothing;

  -- 개인정보 익명화 + 상태 전환(token_version 증가 + status 변경 → 모든 세션 즉시 무효)
  update public.users set
    username = 'del_' || v_tag,
    nickname = '탈퇴회원' || v_tag,
    password_hash = '!',
    phone = null,
    phone_verified = false,
    profile_image_url = null,
    profile_image_thumbnail_url = null,
    profile_image_mime_type = null,
    profile_image_file_size = null,
    address = null,
    latitude = null,
    longitude = null,
    is_location_verified = false,
    region_code = null,
    activity_radius_m = null,
    push_enabled = false,
    marketing_opt_in = false,
    unread_notification_count = 0,
    unread_chat_count = 0,
    active_mode = 'personal',
    status = 'deleted',
    deleted_at = now(),
    token_version = token_version + 1
  where id = v_me and status = 'active';
  if not found then
    raise exception 'not_active_account' using errcode = 'P0001';
  end if;

  -- 개인위치정보 이력 즉시 파기 (약관 제11조③ — 확인자료는 법정 6개월 보존이라 제외)
  delete from public.location_verifications where user_id = v_me;
  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where user_id = v_me
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);
  update public.posts
     set actual_lat = null, actual_lng = null
   where user_id = v_me
     and (actual_lat is not null or actual_lng is not null);

  -- 업체 프로필: 번호·업소 키 반납(부분 유니크 해제) + 서류 30일 파기 큐 (0025 §2.2·§3.3)
  insert into app.business_doc_purge_queue (path, reason, purge_after)
  select p, 'withdraw', now() + interval '30 days'
    from public.business_profiles bp,
         unnest(array_remove(array[bp.license_image_path, bp.extra_doc_path], null)) p
   where bp.user_id = v_me;
  update public.business_profiles
     set status = 'rejected',
         rejected_reason = coalesce(rejected_reason, 'withdrawn'),
         updated_at = now()
   where user_id = v_me and status <> 'rejected';

  -- 세션·푸시·알림 정리
  delete from app.refresh_tokens where user_id = v_me;
  delete from public.device_tokens where user_id = v_me;
  delete from public.notifications where user_id = v_me;
  delete from public.notification_preferences where user_id = v_me;

  -- 소셜 관계 정리 (팔로우 양방향)
  delete from public.pawings where follower_id = v_me or following_id = v_me;

  -- 반려동물: 내가 대표 보호자인 펫은 삭제 처리, 내 보호자 멤버십 제거
  update public.pets set pet_status = 'deleted', updated_at = now()
   where primary_guardian_id = v_me and pet_status <> 'deleted';
  delete from public.pet_guardians where user_id = v_me;

  -- 채팅: 모든 방에서 나가기(목록 숨김 · 상대는 전송 불가 안내)
  update public.chat_room_members set left_at = now(), updated_at = now()
   where user_id = v_me and left_at is null;
end $function$;

revoke all on function public.withdraw_account() from public, anon;
grant execute on function public.withdraw_account() to authenticated;
