-- 세션 회수 시 기기 푸시 토큰도 함께 끈다 — 클라이언트가 구조적으로 못 하던 일.
--
-- ── 왜 클라이언트로는 안 되나 ────────────────────────────────────────────
--
-- 강제 로그아웃(다른 기기에서 비밀번호 변경, 탈퇴 등)은 서버가 token_version 을
-- 올려 세션을 무효화하면서 시작된다. 앱은 그 뒤에야 release_device_token 을
-- 부르는데, 그 RPC 는 app.uid() 를 요구하고 app.uid() 는 token_version 이
-- 맞아야 값을 준다. 즉 **부를 수 있는 시점에는 이미 부를 자격이 없다.**
-- 운영 로그에 그 결과가 그대로 남아 있다:
--   push.releaseToken → PostgrestException(not_authenticated, 42501)
-- 호출 순서를 바꿔도 해결되지 않는다(#237 이 재발한 이유).
--
-- 결과: 이전 계정의 채팅 알림이 그 기기로 계속 갔다.
--
-- ── 왜 트리거인가 ───────────────────────────────────────────────────────
--
-- token_version 을 올리는 곳이 한 군데가 아니다(탈퇴·비밀번호 변경·재설정·
-- 관리자 탈퇴 처리…). 각 함수에 정리 코드를 넣으면 새 경로가 생길 때마다
-- 빠뜨린다. 상태 변화 자체에 거는 편이 누락이 없다.
--
-- refresh 회전은 token_version 을 건드리지 않는다(rt_rotate 가 refresh family 만
-- 돌린다) — 그래서 8시간마다 푸시가 꺼지는 일은 없다.
--
-- 재활성화는 자동이다: register_device_token 이 `on conflict (token) do update`
-- 로 user_id·is_active 를 되살린다. 앱은 시작할 때마다 토큰을 등록한다.

create or replace function app.revoke_device_tokens_on_session_revoke()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  update public.device_tokens
     set is_active = false,
         updated_at = now()
   where user_id = new.id
     and is_active;
  return new;
end $$;

comment on function app.revoke_device_tokens_on_session_revoke() is
  '세션 회수(token_version 증가·비활성 전환) 시 그 사용자의 기기 푸시 토큰을 끈다.';

drop trigger if exists users_revoke_device_tokens on public.users;

-- when 절로 실제 회수일 때만 돈다 — 일반 UPDATE(닉네임 변경 등)에는 부담이 없다.
create trigger users_revoke_device_tokens
  after update on public.users
  for each row
  when (
    new.token_version is distinct from old.token_version
    or (old.status = 'active' and new.status is distinct from 'active')
  )
  execute function app.revoke_device_tokens_on_session_revoke();

comment on trigger users_revoke_device_tokens on public.users is
  '토큰 회수·계정 비활성 시 푸시 토큰 정리 — 클라이언트는 이 시점에 이미 인증을 잃어 못 한다.';
