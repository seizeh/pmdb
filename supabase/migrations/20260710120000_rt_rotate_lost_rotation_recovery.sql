-- refresh 회전 유실 복구 — 세션 소실 버그 수정.
--
-- 증상: 세션 복원 직후 강제 로그아웃. 원인: 회전 응답(새 refresh)이 클라이언트에
-- 저장되기 전에 유실되면(프로세스 킬/네트워크 타임아웃) 다음 실행이 구 토큰을
-- 다시 제시하고, 30초 grace 를 넘긴 재사용을 rt_rotate 가 "탈취"로 오판해
-- 패밀리 전체를 회수 → 401 → 강제 로그아웃.
--
-- 수정: 재사용 판정을 "유실 재시도"와 "탈취"로 구분한다.
--   · 제시된 토큰의 후속(replaced_by)이 **한 번도 사용(회전)되지 않았다면**
--     응답 유실 재시도로 판정 → 미사용 후속을 회수하고 새 토큰 재발급('recovered').
--   · 후속이 이미 사용됐다면(회전 이력 있음) 진짜 탈취 → 패밀리 회수('reuse_revoked').
--   · 복구는 패밀리당 5회/일 제한(rate_limit_hit) — 탈취자가 구 토큰으로
--     정상 사용자와 번갈아 복구하는 핑퐁 악용을 차단(한도 초과 시 패밀리 회수).
--
-- 함께 수정: ① grace 분기의 token_version 모호 참조(OUT 파라미터와 충돌 →
-- 런타임 에러, 잠복 버그) 별칭으로 한정 ② 로그아웃/패밀리 회수로 죽은 토큰
-- (replaced_by 없음)은 grace 대상에서 제외 — 로그아웃 직후 30초 내 재사용으로
-- 세션이 부활하던 구멍 차단.
create or replace function public.rt_rotate(
  p_old_hash text, p_new_hash text, p_user_agent text default null, p_grace_seconds integer default 30)
returns table(result text, user_id uuid, token_version integer)
language plpgsql security definer set search_path to '' as $function$
declare
  r app.refresh_tokens;
  s app.refresh_tokens;
  v_now timestamptz := now();
  v_aff int;
  v_tv int;
  v_new_id uuid;
begin
  select * into r from app.refresh_tokens where token_hash = p_old_hash;
  if not found then return query select 'invalid', null::uuid, null::int; return; end if;

  if not exists (select 1 from public.users u where u.id = r.user_id and u.status='active') then
    update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
      where family_id = r.family_id and revoked_at is null;
    return query select 'inactive', r.user_id, null::int; return;
  end if;
  if v_now > r.absolute_expires_at or v_now > r.expires_at then
    return query select 'expired', r.user_id, null::int; return;
  end if;

  if r.revoked_at is null then
    update app.refresh_tokens set revoked_at = v_now where id = r.id and revoked_at is null;
    get diagnostics v_aff = row_count;
    if v_aff > 0 then
      insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
      values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent);
      update app.refresh_tokens set replaced_by = (select id from app.refresh_tokens where token_hash = p_new_hash)
        where id = r.id;
      select u.token_version into v_tv from public.users u where u.id = r.user_id;
      return query select 'rotated', r.user_id, coalesce(v_tv,0); return;
    end if;
    -- v_aff=0: 동시 회전됨 → 아래 revoked 분기로
    select * into r from app.refresh_tokens where id = r.id;
  end if;

  -- 여기 도달 = 이미 revoked. ① 직후 동시요청(grace) ② 회전 응답 유실 재시도 ③ 탈취.
  --
  -- replaced_by 가 없는 revoked 토큰 = 회전이 아니라 로그아웃/패밀리 회수로 죽은 것.
  -- 이런 토큰은 grace/복구 대상이 아니다(로그아웃 직후 재사용으로 세션 부활 방지).
  if r.replaced_by is null then
    update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
      where family_id = r.family_id and revoked_at is null;
    return query select 'reuse_revoked', r.user_id, null::int; return;
  end if;

  -- ① 회전 직후 grace(동시요청·즉시 재시도) — 추가 토큰 발급.
  if v_now - r.revoked_at <= make_interval(secs => p_grace_seconds) then
    insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
    values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent);
    select u.token_version into v_tv from public.users u where u.id = r.user_id;
    return query select 'grace', r.user_id, coalesce(v_tv,0); return;
  end if;

  -- ② 유실 재시도: 후속 토큰이 한 번도 사용(회전)되지 않은 경우 — 응답을 못 받은
  --    클라이언트만 구 토큰을 다시 낼 수 있다. 미사용 후속을 회수하고 새 토큰을
  --    재발급해 세션을 복구한다(패밀리당 5회/일 제한).
  select * into s from app.refresh_tokens where id = r.replaced_by;
  if found and s.revoked_at is null and s.replaced_by is null
     and public.rate_limit_hit('rtrec:' || r.family_id::text, 5, 86400) then
    update app.refresh_tokens set revoked_at = v_now where id = s.id;
    insert into app.refresh_tokens(user_id, token_hash, family_id, expires_at, absolute_expires_at, user_agent)
    values (r.user_id, p_new_hash, r.family_id, v_now + interval '30 days', r.absolute_expires_at, p_user_agent)
    returning id into v_new_id;
    update app.refresh_tokens set replaced_by = v_new_id where id = s.id;
    select u.token_version into v_tv from public.users u where u.id = r.user_id;
    return query select 'recovered', r.user_id, coalesce(v_tv,0); return;
  end if;

  -- ③ 탈취(후속이 이미 사용됨) / 복구 한도 초과 → 패밀리 전체 회수
  update app.refresh_tokens set revoked_at = coalesce(revoked_at, v_now)
    where family_id = r.family_id and revoked_at is null;
  return query select 'reuse_revoked', r.user_id, null::int; return;
end $function$;

revoke all on function public.rt_rotate(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.rt_rotate(text, text, text, integer) to service_role;
