-- 세션 유효성 확인 RPC: 현재 JWT 가 활성 사용자 + token_version 일치로 app.uid 를 해석하면 true.
-- 앱이 시작/포그라운드 복귀 시 호출해, 타 기기 비번변경/재설정·정지로 무효화된 세션을 감지하고
-- 강제 로그아웃(라우팅)하는 데 쓴다. app.uid() 게이트를 그대로 재사용한다.
create or replace function public.session_alive()
returns boolean
language sql
stable
set search_path to ''
as $$ select app.uid() is not null $$;

grant execute on function public.session_alive() to anon, authenticated;
