-- 클라이언트가 부를 수 있어야 하는 두 가지를 public 으로 노출한다.
-- (app 스키마는 PostgREST 에 노출되지 않아 .rpc() 로 못 부른다.)
--
-- 1) release_device_token — 로그아웃 시 **서버측** 푸시 토큰 비활성화 (pmdart #237)
--
--    지금은 로그아웃이 기기측 FCM deleteToken() 에만 의존한다. 오프라인 로그아웃이면
--    그 호출이 실패하는데(로그아웃을 막지 않으려 의도적으로 삼킨다), 그러면
--    **FCM 토큰도 서버 행도 살아 있다.** 주석이 기대한 안전망("다음 발송 실패로
--    자동 비활성화")은 토큰이 유효하니 발송이 성공해서 발동하지 않는다.
--    결과: 비행기 모드에서 로그아웃한 기기가 이전 계정의 채팅 내용을 무기한 계속 받는다.
--    공용·양도 기기에서 개인정보가 샌다.
--
--    app.deactivate_device_token 은 이미 있지만 **토큰만 알면 누구든 끌 수 있다**
--    (Edge Function 이 APNs/FCM 응답으로 부르는 용도라 소유자 검사가 없다).
--    그대로 public 에 열면 남의 기기 푸시를 끄는 경로가 된다 — 소유자 게이트를 씌운다.
--
-- 2) reconcile_my_unread_counts — 본인 안읽음 카운터 보정 (pmdart #232)
--
--    카운터는 트리거로 증감하는 캐시라 원본과 어긋날 수 있다. 실제로 어긋나 있었다
--    (2026-08-03 운영 확인: 80 vs 2, 32 vs 2). DELETE 분기는 20260717150000 에서
--    이미 고쳤지만 그 전에 쌓인 값은 그대로 남아 있었고, 앱에서 보정을 부를 방법이
--    없었다(app 스키마라 .rpc() 불가). 로그인 시 한 번 부를 수 있게 연다.

-- ── 1) 푸시 토큰 해제 ─────────────────────────────────────────────────────
create or replace function public.release_device_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_token is null or length(p_token) < 10 then
    raise exception 'invalid_token' using errcode = 'P0001';
  end if;

  -- **소유자 행만** 끈다. 남의 토큰을 지정해도 0행이 갱신될 뿐 오류를 내지 않는다
  -- (오류를 내면 "이 토큰이 누구 것인지" 를 알려주는 열거 통로가 된다).
  update public.device_tokens
     set is_active  = false,
         updated_at = now()
   where token = p_token
     and user_id = v_uid;
end $$;

comment on function public.release_device_token(text) is
  '로그아웃 시 본인 기기 푸시 토큰 비활성화. 소유자 행만 끈다(남의 토큰은 무시).';

revoke all on function public.release_device_token(text) from public;
grant execute on function public.release_device_token(text) to authenticated;

-- ── 2) 안읽음 카운터 자가 보정 ────────────────────────────────────────────
-- 인자를 받지 않는다. app.reconcile_unread_counts(uuid) 를 그대로 열면
-- 관리자가 아닌 호출자도 남의 uuid 를 넣어 볼 수 있는지 헷갈릴 여지가 생긴다
-- (내부 함수가 막고는 있지만, 공개 API 는 애초에 인자를 안 받는 게 낫다).
create or replace function public.reconcile_my_unread_counts()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  perform app.reconcile_unread_counts(v_uid);
end $$;

comment on function public.reconcile_my_unread_counts() is
  '본인 unread_chat_count·unread_notification_count 를 원본에서 재계산. 로그인 시 안전망.';

revoke all on function public.reconcile_my_unread_counts() from public;
grant execute on function public.reconcile_my_unread_counts() to authenticated;

notify pgrst, 'reload schema';
