-- 비밀번호 재설정 인증을 **소진**시킨다 — 30분 재사용 창을 닫는다.
--
-- ── 무엇이 문제였나 ────────────────────────────────────────────────────────
-- reset_password_user 는 이렇게만 확인한다:
--
--   "phone + purpose='password_reset' + is_used=true + created_at > now()-30분
--    행이 **존재하는가**"
--
-- 코드값을 다시 받지도(엣지 함수가 code 를 아예 인자로 받지 않는다), 그 행을
-- 소진하지도 않는다. 즉 **인증 1회로 30분짜리 열쇠가 열려 있고 몇 번이든 쓸 수 있다.**
--
-- 결과: 피해자가 정상 재설정을 1회 완료하면 그 후 30분 동안, 번호만 아는 제3자가
-- `{phone, new_password}` 만 보내 비밀번호를 덮어쓸 수 있다.
--
-- ── 더 나쁜 것 — 이 엔드포인트가 무료 오라클이다 ─────────────────────────
-- reset-password 에는 레이트리밋이 없었다(#151 도 이 함수는 건드리지 않는다).
-- 그래서 `403 phone_not_verified` 와 `200 ok` 의 차이가
-- **"이 번호가 최근 30분 안에 재설정을 했는가"** 를 공짜로 알려준다.
-- 번호 목록을 계속 찔러 보며 창이 열리기를 기다리는 게 비용 없이 가능했다.
--
-- ── 왜 아무도 몰랐나 ──────────────────────────────────────────────────────
-- 정상 사용자는 인증 직후 곧바로 새 비번을 넣고 끝낸다. 창이 그 뒤로도 열려 있다는
-- 사실이 화면에 드러날 일이 없다. 실패한 시도도 어디에도 기록되지 않는다.
--
-- ── 경로 간 비대칭이 근거다 ───────────────────────────────────────────────
-- 같은 비소진 RPC 를 쓰는 다른 두 경로는 각자 창을 닫아 두었다:
--   signup-lite — 엣지가 코드 일치를 직접 확인하고 is_used 를 찍는다(창 없음)
--   signup      — users_phone_uq 가 2차 방어(같은 번호로 두 번 못 만든다)
-- **reset-password 만 어느 쪽도 없었다.**
--
-- ── 조치 ──────────────────────────────────────────────────────────────────
-- 비밀번호를 실제로 바꾼 뒤 그 번호의 password_reset 인증 행을 지운다.
-- 같은 트랜잭션 안이라 "바꿨는데 소진이 안 된" 상태가 생기지 않는다.
-- (retention 배치가 어차피 1일 뒤 지우므로 보존 정책과도 어긋나지 않는다.)
--
-- 남는 창: "인증 완료 ~ 정상 사용자가 새 비번 제출" 사이 수 초. 그 구간을 노리려면
-- 폴링이 필요한데 엣지 함수에 레이트리밋을 함께 넣어 값을 매겼다.
create or replace function public.reset_password_user(p_phone text, p_new_hash text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  -- 전화 인증 완료 확인(password_reset 목적, 사용처리됨, 30분 이내)
  if not exists (
    select 1 from public.phone_verifications
    where phone = p_phone
      and purpose = 'password_reset'
      and is_used = true
      and created_at > now() - interval '30 minutes'
  ) then
    raise exception 'phone_not_verified' using errcode = 'P0001';
  end if;

  select id into v_id from public.users where phone = p_phone;
  if v_id is null then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  -- 비번 갱신 + 전 세션 무효화(token_version bump + refresh 전량 회수)
  update public.users
     set password_hash = p_new_hash,
         token_version = token_version + 1
   where id = v_id;
  update app.refresh_tokens set revoked_at = now()
   where user_id = v_id and revoked_at is null;

  -- ▼ 인증 소진 — 한 번의 인증으로 두 번 바꿀 수 없게. 이 줄이 없으면 위 게이트는
  --   "30분 동안 아무나 쓸 수 있는 열쇠" 가 된다.
  delete from public.phone_verifications
   where phone = p_phone
     and purpose = 'password_reset';

  return v_id;
end;
$$;

comment on function public.reset_password_user(text, text) is
  '전화 인증 확인 후 비밀번호 재설정 + 전 세션 무효화. 사용한 인증은 소진(재사용 차단).';

notify pgrst, 'reload schema';
