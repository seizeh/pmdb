-- 로그아웃·세션 회수 직후 grace 로 세션이 부활하던 구멍을 막는다.
--
-- ── 무엇이 뚫려 있었나 ──────────────────────────────────────────────────
--
-- rt_rotate 는 revoked 토큰이 다시 오면 세 경우를 구분한다: ① 회전 직후
-- 동시요청(grace) ② 회전 응답 유실 재시도(recover) ③ 탈취. 로그아웃으로 죽은
-- 토큰을 ①②로 오인하면 세션이 되살아나므로, 다음 방어가 들어가 있었다:
--
--     if r.replaced_by is null then ... reuse_revoked
--
-- "회전으로 죽은 토큰은 replaced_by 가 있고, 로그아웃으로 죽은 토큰은 없다" 는
-- 전제다. 그런데 **로그아웃 직전에 회전이 한 번 일어나면** 그 전제가 깨진다.
--
--     R1 --회전--> R2      (R1: revoked, replaced_by=R2  ← 회전으로 죽음)
--     로그아웃(rt_revoke_family)  (R2: revoked, replaced_by=null)
--     낡은 R1 로 rt_rotate 재시도 → replaced_by 가 있으니 방어를 통과
--                                → 30초 grace 안이면 새 토큰 발급 → 세션 부활
--
-- 운영 DB 롤백 트랜잭션으로 재현했다(결과 'grace', 살아있는 토큰 1개).
-- 로그아웃 직전 회전은 드문 일이 아니다 — 클라이언트가 로그아웃 요청을 보낼 때
-- access 만료가 가까우면 그 호출 자체가 회전을 먼저 유발한다.
--
-- 같은 창이 rt_revoke_user 경로(비밀번호 변경·정지로 인한 타 기기 회수)에도
-- 열려 있었다. 회수당한 기기가 30초 안에 낡은 토큰으로 재시도하면 살아난다.
--
-- ── 무엇으로 고치나 ─────────────────────────────────────────────────────
--
-- 죽은 원인은 **후속 토큰의 상태**에 남는다. 회전으로 죽었으면 후속은 살아 있거나
-- (또 회전됐다면) 자기 replaced_by 를 갖는다. 패밀리 회수로 죽었으면 후속은
-- **replaced_by 없이 revoked** 다 — 회수만이 남기는 흔적이다. 그래서 grace 를
-- 주기 전에 후속을 보고, 그 흔적이 있으면 거절한다.
--
-- 연쇄 회전(R1→R2→R3)이 30초 안에 일어난 경우는 후속 R2 가 replaced_by 를
-- 가지므로 그대로 grace 를 받는다 — 정상 동시요청 구제는 좁아지지 않는다.
--
-- ②(recover) 분기는 이미 `s.revoked_at is null` 을 요구해 이 창이 없다.
-- 나머지 본문은 20260710120000 정의와 같다.

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
  v_has_successor boolean := false;
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

  -- 후속 토큰의 상태로 "회전으로 죽었나 / 회수로 죽었나" 를 가른다.
  -- 후속이 **replaced_by 없이 revoked** = 이 패밀리는 회수당했다(로그아웃·비번변경·정지).
  -- 그 경우 이 토큰도 죽은 세션의 일부이므로 ①②를 주지 않는다.
  select * into s from app.refresh_tokens where id = r.replaced_by;
  v_has_successor := found;
  if not v_has_successor or (s.revoked_at is not null and s.replaced_by is null) then
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
  if s.revoked_at is null and s.replaced_by is null
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

comment on function public.rt_rotate(text, text, text, integer) is
  'refresh 원자 회전. revoked 재사용은 후속 토큰 상태로 판정 — 패밀리 회수(로그아웃·비번변경) 후에는 grace/복구를 주지 않는다.';
