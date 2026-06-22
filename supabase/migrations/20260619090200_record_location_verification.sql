-- 0017 지역 인증 — 인증 결과를 한 트랜잭션으로 반영하는 RPC.
--
-- verify-location Edge Function 이 service_role 로 호출한다. 성공/실패/차단을
-- 모두 이 함수에서 처리한다:
--   - 이력 로그(location_verifications) insert (반경 = GPS 정확도)
--   - 성공 시 users 인증 컬럼 갱신 + fail_count 리셋 + 차단 해제
--   - 실패 시 fail_count 누적 → 임계 초과 시 차단 설정
--
-- 인증 컬럼(is_location_verified / region_code / latitude / longitude /
-- last_verified_at / location_verify_*)은 클라이언트 GRANT 가 없으므로
-- 오직 이 SECURITY DEFINER 경로(소유자 권한으로 컬럼 GRANT 우회)로만 변경된다.
--
-- 주의: 설계 문서(0017)는 app 스키마를 적었으나, app 스키마는 PostgREST 에
-- 노출되지 않은 내부 헬퍼/트리거 전용이다. Edge Function 의
-- supabase.rpc('record_location_verification') 는 노출 스키마(public)에서
-- 함수를 찾으므로 public 에 둔다. 클라이언트 호출은 아래 revoke 로 차단한다.
create or replace function public.record_location_verification(
  p_user          uuid,
  p_lat           numeric,
  p_lng           numeric,
  p_accuracy      int,
  p_result        text,           -- 'success' | 'failed' | 'blocked'
  p_region_code   varchar,
  p_address       varchar,
  p_fail_reason   varchar,
  p_fail_limit    int default 5,
  p_block_minutes int default 60
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 이력 로그(반경 = GPS 정확도, NOT NULL 이라 음수/널 방어)
  insert into public.location_verifications
    (user_id, verified_lat, verified_lng, verified_radius_meters, result, fail_reason)
  values
    (p_user, p_lat, p_lng, greatest(coalesce(p_accuracy, 0), 0), p_result, p_fail_reason);

  if p_result = 'success' then
    update public.users
       set latitude = p_lat,
           longitude = p_lng,
           region_code = p_region_code,
           address = p_address,
           is_location_verified = true,
           last_verified_at = now(),
           location_verify_fail_count = 0,
           location_verify_blocked_until = null,
           updated_at = now()
     where id = p_user;
  else
    -- 실패 누적 → 임계 초과 시 차단
    update public.users
       set location_verify_fail_count = location_verify_fail_count + 1,
           location_verify_blocked_until = case
             when location_verify_fail_count + 1 >= p_fail_limit
               then now() + make_interval(mins => p_block_minutes)
             else location_verify_blocked_until end,
           updated_at = now()
     where id = p_user;
  end if;
end;
$$;

-- 클라이언트(anon/authenticated)는 호출 불가. service_role(Edge Function) 전용.
revoke all on function public.record_location_verification(
  uuid, numeric, numeric, int, text, varchar, varchar, varchar, int, int)
  from public, anon, authenticated;
grant execute on function public.record_location_verification(
  uuid, numeric, numeric, int, text, varchar, varchar, varchar, int, int)
  to service_role;
