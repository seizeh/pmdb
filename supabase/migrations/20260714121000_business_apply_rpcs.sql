-- 업체 등록 신청 RPC + 계정 전환 RPC (0025 §4~§5).
-- apply_business_profile 은 apply-business 엣지 전용(service_role) — 국세청 재조회를 마친
-- 서버 값만 들어온다. 매칭·점수·트랙 판정 전부 서버 계산(0025 설계 원칙 1).

-- 1) 신청/재신청 — facilities 대조·점수제 (0025 §4.3~4.4)
create or replace function public.apply_business_profile(
  p_user            uuid,
  p_b_no            text,
  p_category        text,
  p_business_name   text,
  p_storefront_name text,
  p_prev_name       text,
  p_address_road    text,
  p_address_jibun   text,
  p_region_code     text,
  p_phone           text,
  p_rep_name        text,
  p_email           text,
  p_license_path    text,
  p_extra_doc_path  text,
  p_nts_status_code text
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  -- 규칙(배점·임계값·스위치) — business_match_rules 에서 로드, 행 없으면 시드 기본값
  v_w_phone int;  v_on_phone boolean;
  v_w_name_high int; v_on_name_high boolean; v_sim_high real;
  v_w_name_mid int;  v_on_name_mid boolean;  v_sim_mid real;
  v_w_region int; v_on_region boolean;
  v_w_addr int;   v_on_addr boolean;   v_sim_addr real;
  v_w_cat int;    v_on_cat boolean;
  v_thr_auto int; v_thr_review int; v_auto_on boolean;
  -- 정규화 입력
  v_names text[];
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_region5 text := left(regexp_replace(coalesce(p_region_code, ''), '\D', '', 'g'), 5);
  v_naddr text := app.norm_biz_text(p_address_jibun);
  -- 매칭 결과 (물리 업소 = biz_key 그룹 단위, 0025 §4.3)
  v_biz_key text; v_score int; v_name_sim real; v_phone_ok boolean; v_any_open boolean;
  v_cats text[]; v_region_ok boolean; v_addr_sim real; v_rep_id uuid;
  v_tie_cnt int; v_grp_cnt int; v_cat_ok boolean;
  v_track text; v_status text; v_auto_approved boolean;
  v_detail jsonb;
  -- 기존 행(재신청)
  v_old_status text; v_old_license text; v_old_extra text;
  v_constraint text;
begin
  -- 입력 검증 (엣지가 1차 검증하지만 최종 방어선)
  if p_user is null then raise exception 'invalid_user' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.users u where u.id = p_user and u.status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;
  if coalesce(p_b_no, '') !~ '^\d{10}$' then
    raise exception 'invalid_business_no' using errcode = 'P0001';
  end if;
  if p_category not in ('pet_sales','pet_hotel','animal_hospital','grooming','other') then
    raise exception 'invalid_category' using errcode = 'P0001';
  end if;
  if nullif(btrim(coalesce(p_business_name,'')), '') is null
     or nullif(btrim(coalesce(p_address_road,'')), '') is null
     or nullif(btrim(coalesce(p_email,'')), '') is null
     or nullif(btrim(coalesce(p_license_path,'')), '') is null then
    raise exception 'missing_fields' using errcode = 'P0001';
  end if;
  -- 국세청 계속사업자(01)만 — 엣지가 서버측 재조회한 값 (0025 §3.1)
  if coalesce(p_nts_status_code, '') <> '01' then
    raise exception 'nts_not_active' using errcode = 'P0001';
  end if;

  -- 기존 행 상태: pending/approved 중 재제출 차단(0025 §5 — 보완은 관리자 반려 후에만)
  select bp.status, bp.license_image_path, bp.extra_doc_path
    into v_old_status, v_old_license, v_old_extra
    from public.business_profiles bp where bp.user_id = p_user;
  if v_old_status = 'pending' then raise exception 'already_pending' using errcode = 'P0001'; end if;
  if v_old_status = 'approved' then raise exception 'already_approved' using errcode = 'P0001'; end if;

  -- 규칙 로드 (행이 없으면 0025 §2.5 시드값)
  select
    coalesce(max(weight)      filter (where rule_key = 'phone_exact'), 35),
    coalesce(bool_or(enabled) filter (where rule_key = 'phone_exact'), true),
    coalesce(max(weight)      filter (where rule_key = 'name_high'), 30),
    coalesce(bool_or(enabled) filter (where rule_key = 'name_high'), true),
    coalesce(max((params->>'sim')::real) filter (where rule_key = 'name_high'), 0.85),
    coalesce(max(weight)      filter (where rule_key = 'name_mid'), 20),
    coalesce(bool_or(enabled) filter (where rule_key = 'name_mid'), true),
    coalesce(max((params->>'sim')::real) filter (where rule_key = 'name_mid'), 0.60),
    coalesce(max(weight)      filter (where rule_key = 'addr_region'), 10),
    coalesce(bool_or(enabled) filter (where rule_key = 'addr_region'), true),
    coalesce(max(weight)      filter (where rule_key = 'addr_sim'), 10),
    coalesce(bool_or(enabled) filter (where rule_key = 'addr_sim'), false),
    coalesce(max((params->>'sim')::real) filter (where rule_key = 'addr_sim'), 0.70),
    coalesce(max(weight)      filter (where rule_key = 'category_match'), 15),
    coalesce(bool_or(enabled) filter (where rule_key = 'category_match'), true),
    coalesce(max(weight)      filter (where rule_key = 'threshold_auto'), 80),
    coalesce(max(weight)      filter (where rule_key = 'threshold_review'), 50),
    coalesce(bool_or(enabled) filter (where rule_key = 'auto_approve_enabled'), false)
  into v_w_phone, v_on_phone,
       v_w_name_high, v_on_name_high, v_sim_high,
       v_w_name_mid, v_on_name_mid, v_sim_mid,
       v_w_region, v_on_region,
       v_w_addr, v_on_addr, v_sim_addr,
       v_w_cat, v_on_cat,
       v_thr_auto, v_thr_review, v_auto_on
  from public.business_match_rules;

  -- 대조 이름: 현 상호·사업장명·이전 상호 정규화(중복·공백 제거) — max 유사도 사용 (0025 §4.2)
  v_names := array(
    select distinct n from unnest(array[
      app.norm_biz_text(p_business_name),
      app.norm_biz_text(p_storefront_name),
      app.norm_biz_text(p_prev_name)
    ]) n where n is not null and n <> ''
  );

  -- 후보 검색 → 물리 업소(biz_key) 그룹핑 → 점수 (0025 §4.3~4.4).
  -- pet_cafe 제외(정책). is_open 필터 없음 — 폐업 표시는 데이터 지연일 수 있어 후보에 포함하되
  -- 자동승인만 막는다(예외표 Case 7). 24.5k 행 전수 유사도 계산은 신청 단위 RPC 라 허용.
  if p_category <> 'other' then
    with cand as (
      select f.id, f.category::text as category, f.is_open, f.region_code,
             app.norm_biz_text(f.name::text) as nname,
             app.norm_biz_text(coalesce(f.address, '')) as naddr,
             regexp_replace(coalesce(f.phone, ''), '\D', '', 'g') as nphone,
             (select max(extensions.similarity(app.norm_biz_text(f.name::text), n))
                from unnest(v_names) n) as name_sim
        from public.facilities f
       where f.category in ('pet_sales','pet_hotel','animal_hospital','grooming')
    ),
    hit as (
      select * from cand
       where coalesce(name_sim, 0) >= v_sim_mid
          or (v_phone <> '' and nphone = v_phone)
    ),
    grp as (
      select h.nname || '|' || h.naddr as biz_key,
             max(h.name_sim) as name_sim,
             bool_or(v_phone <> '' and h.nphone = v_phone) as phone_ok,
             bool_or(h.is_open) as any_open,
             array_agg(distinct h.category) as cats,
             bool_or(v_region5 <> '' and h.region_code is not null
                     and left(h.region_code, 5) = v_region5) as region_ok,
             max(extensions.similarity(h.naddr, v_naddr)) as addr_sim,
             (array_agg(h.id order by (h.category = p_category)::int desc, h.id))[1] as rep_id
        from hit h
       group by h.nname || '|' || h.naddr
    ),
    scored as (
      select g.*,
             ( case when v_on_phone and g.phone_ok then v_w_phone else 0 end
             + case when v_on_name_high and g.name_sim >= v_sim_high then v_w_name_high
                    when v_on_name_mid  and g.name_sim >= v_sim_mid  then v_w_name_mid
                    else 0 end
             + case when v_on_region and g.region_ok then v_w_region else 0 end
             + case when v_on_addr and coalesce(g.addr_sim, 0) >= v_sim_addr then v_w_addr else 0 end
             + case when v_on_cat and p_category = any(g.cats) then v_w_cat else 0 end
             )::int as score
        from grp g
    )
    select s.biz_key, s.score, s.name_sim, s.phone_ok, s.any_open, s.cats,
           s.region_ok, s.addr_sim, s.rep_id,
           (select count(*) from scored s2 where s2.score = s.score),
           (select count(*) from scored)
      into v_biz_key, v_score, v_name_sim, v_phone_ok, v_any_open, v_cats,
           v_region_ok, v_addr_sim, v_rep_id, v_tie_cnt, v_grp_cnt
      from scored s
     order by s.score desc, s.biz_key
     limit 1;
  end if;

  v_cat_ok := v_cats is not null and p_category = any(v_cats);

  -- 트랙 판정 — 필수 신호(전화·업종)는 합계와 별개의 AND (0025 §4.4, 설계 원칙 2)
  if p_category = 'other' or v_biz_key is null or v_score < v_thr_review then
    v_track := 'new_business';
  elsif v_phone_ok and v_cat_ok and v_tie_cnt = 1 and v_any_open and v_score >= v_thr_auto then
    v_track := 'auto';
  else
    v_track := 'review';
  end if;

  -- 신규개업 트랙: 추가 서류를 INSERT '전에' 요구 — pending 행이 생기면 본인이 보완 불가 (0025 §4.5)
  if v_track = 'new_business' and nullif(btrim(coalesce(p_extra_doc_path, '')), '') is null then
    raise exception 'extra_doc_required' using errcode = 'P0001';
  end if;

  v_auto_approved := v_track = 'auto' and v_auto_on;
  v_status := case when v_auto_approved then 'approved' else 'pending' end;

  -- 저확신(new_business)은 업소 키를 점유하지 않는다 — 오매칭이 실존 업소를 잠그는 것 방지
  if v_track = 'new_business' then
    v_biz_key := null; v_rep_id := null;
  end if;

  v_detail := jsonb_build_object(
    'name_sim',    round(coalesce(v_name_sim, 0)::numeric, 3),
    'phone_ok',    coalesce(v_phone_ok, false),
    'region_ok',   coalesce(v_region_ok, false),
    'addr_sim',    round(coalesce(v_addr_sim, 0)::numeric, 3),
    'category_ok', coalesce(v_cat_ok, false),
    'categories',  to_jsonb(coalesce(v_cats, '{}'::text[])),
    'tie_count',   coalesce(v_tie_cnt, 0),
    'group_count', coalesce(v_grp_cnt, 0),
    'any_open',    coalesce(v_any_open, false),
    'weights', jsonb_build_object(
      'phone', v_w_phone, 'name_high', v_w_name_high, 'name_mid', v_w_name_mid,
      'addr_region', v_w_region, 'addr_sim', v_w_addr, 'category', v_w_cat,
      'thr_auto', v_thr_auto, 'thr_review', v_thr_review),
    'auto_switch', v_auto_on
  );

  -- upsert (재신청 = rejected 행 갱신, 0025 §5). 유니크 위반 → 친절한 에러코드로 매핑
  begin
    insert into public.business_profiles as bp (
      user_id, business_reg_no, declared_category, business_name, storefront_name,
      prev_business_name, business_address, business_address_jibun, business_region_code,
      business_phone, representative_name, contact_email, license_image_path, extra_doc_path,
      nts_status_code, nts_checked_at, matched_facility_id, matched_biz_key,
      match_score, match_detail, review_track, auto_approved, status
    ) values (
      p_user, p_b_no, p_category, btrim(p_business_name), nullif(btrim(coalesce(p_storefront_name,'')), ''),
      nullif(btrim(coalesce(p_prev_name,'')), ''), btrim(p_address_road),
      nullif(btrim(coalesce(p_address_jibun,'')), ''), nullif(v_region5, ''),
      nullif(v_phone, ''), nullif(btrim(coalesce(p_rep_name,'')), ''), btrim(p_email),
      p_license_path, nullif(btrim(coalesce(p_extra_doc_path,'')), ''),
      p_nts_status_code, now(), v_rep_id, v_biz_key,
      v_score, v_detail, v_track, v_auto_approved, v_status
    )
    on conflict (user_id) do update set
      business_reg_no = excluded.business_reg_no,
      declared_category = excluded.declared_category,
      business_name = excluded.business_name,
      storefront_name = excluded.storefront_name,
      prev_business_name = excluded.prev_business_name,
      business_address = excluded.business_address,
      business_address_jibun = excluded.business_address_jibun,
      business_region_code = excluded.business_region_code,
      business_phone = excluded.business_phone,
      representative_name = excluded.representative_name,
      contact_email = excluded.contact_email,
      license_image_path = excluded.license_image_path,
      extra_doc_path = excluded.extra_doc_path,
      nts_status_code = excluded.nts_status_code,
      nts_checked_at = excluded.nts_checked_at,
      matched_facility_id = excluded.matched_facility_id,
      matched_biz_key = excluded.matched_biz_key,
      match_score = excluded.match_score,
      match_detail = excluded.match_detail,
      review_track = excluded.review_track,
      auto_approved = excluded.auto_approved,
      status = excluded.status,
      rejected_reason = null, reviewed_by = null, reviewed_at = null, review_note = null,
      updated_at = now();
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'business_profiles_regno_active_uq' then
      raise exception 'business_no_taken' using errcode = 'P0001';
    elsif v_constraint = 'business_profiles_bizkey_active_uq' then
      raise exception 'facility_taken' using errcode = 'P0001';
    else
      raise;
    end if;
  end;

  -- 재신청이 반려 때 큐에 올라간 같은 파일을 재사용하면 파기 취소
  delete from app.business_doc_purge_queue q
   where q.purged_at is null
     and q.path in (p_license_path, coalesce(p_extra_doc_path, ''));

  -- 교체된 옛 서류는 30일 후 파기 (0025 §3.3)
  if v_old_license is not null and v_old_license <> p_license_path then
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_old_license, 'superseded', now() + interval '30 days');
  end if;
  if v_old_extra is not null and v_old_extra is distinct from p_extra_doc_path then
    insert into app.business_doc_purge_queue (path, reason, purge_after)
    values (v_old_extra, 'superseded', now() + interval '30 days');
  end if;

  -- 자동승인: 알림 + 감사로그(admin_id null = 시스템, 0025 §4.6)
  if v_auto_approved then
    insert into public.notifications (user_id, notification_type, is_system, title, body)
    values (p_user, 'business_approved', true, '업체 인증이 완료되었어요',
            '입력하신 정보가 확인되어 업체 인증이 자동 승인되었어요. 내정보 수정에서 업체 모드로 전환할 수 있어요.');
    insert into public.admin_logs (admin_id, action_type, target_type, target_id, detail)
    values (null, 'business_auto_approved', 'user', p_user,
            v_detail || jsonb_build_object('score', v_score));
  end if;

  return jsonb_build_object('track', v_track, 'status', v_status, 'score', v_score);
end;
$function$;

-- service_role 전용 (signup_user 컨벤션)
revoke all on function public.apply_business_profile(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text) from public;
revoke all on function public.apply_business_profile(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text) from anon;
revoke all on function public.apply_business_profile(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text) from authenticated;

-- 2) 계정 전환 (0025 §2.3) — business 는 approved 일 때만
create or replace function public.switch_account_mode(p_mode text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare v_me uuid := app.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  if p_mode not in ('personal', 'business') then
    raise exception 'invalid_mode' using errcode = 'P0001';
  end if;
  if p_mode = 'business' and not exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_me and bp.status = 'approved'
  ) then
    raise exception 'business_not_approved' using errcode = 'P0001';
  end if;
  update public.users set active_mode = p_mode where id = v_me;
  return p_mode;
end;
$function$;

revoke all on function public.switch_account_mode(text) from public, anon;
grant execute on function public.switch_account_mode(text) to authenticated;
