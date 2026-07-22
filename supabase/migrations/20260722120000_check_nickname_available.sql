-- ============================================================================
-- 닉네임 중복확인 RPC — 내정보 수정 실시간 선체크용.
--
-- check_username_available 과 같은 패턴: 특정 문자열의 존재 여부 boolean 만
-- 반환한다(열거 방어 — 목록 조회 불가). 최종 판정은 어디까지나
-- users_lower_nickname_uq(lower(nickname) 유니크 인덱스)가 한다 — 이 함수는
-- 확인~저장 사이 경합을 막지 못하는 UX 선체크일 뿐이다.
--
-- 본인 현재 닉네임은 '사용 가능'으로: 호출자(app.uid()) 행은 제외한다.
-- (수정 화면에서 닉네임을 안 바꾸고 저장해도 사용 중으로 뜨지 않게.)
--
-- grant 는 authenticated 만 — 닉네임 변경은 로그인 후에만 가능하고,
-- 가입 시점 중복은 signup 엣지가 nickname_taken 으로 이미 처리한다
-- (anon 실행권 최소화 방침, 20260718065841 참조).
-- ============================================================================

create or replace function public.check_nickname_available(p_nickname text)
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select not exists (
    select 1 from public.users
    where lower(nickname) = lower(trim(p_nickname))
      and id is distinct from app.uid()
  );
$function$;

revoke all on function public.check_nickname_available(text) from public;
grant execute on function public.check_nickname_available(text) to authenticated;
