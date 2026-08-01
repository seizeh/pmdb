-- 익명 레이트리밋의 IP 출처를 x-forwarded-for → cf-connecting-ip 로 바꾼다.
--
-- 직전 마이그레이션(20260801090000)에 이렇게 적었다:
--
--   "IP 는 PostgREST 요청 헤더에서 서버가 직접 뽑는다(클라이언트가 못 속인다)."
--
-- **확인해 보니 틀렸다.** 코드는 x-forwarded-for 의 맨 왼쪽 항목을 썼는데, XFF 는
-- 프록시가 뒤에 덧붙이는 헤더라 맨 왼쪽은 **클라이언트가 주장한 값**이다.
-- 운영에 직접 쏴서 확인했다:
--
--   위조 없음                 → xff = "115.91.115.38"                (실제 IP)
--   X-Forwarded-For: 9.9.9.9  → xff = "9.9.9.9,115.91.115.38"        ← 맨 왼쪽이 공격자 값
--
-- 즉 XFF 를 매 요청 바꾸면 30/분 버킷이 무한히 생겨 1단이 무력화된다.
-- (2단 전역 300/분 이 남아 있어 피해는 '수정 전 상태로 복귀' 수준이고, 원래 막으려던
--  시나리오 — 정상 브라우저 하나의 우발적 오류 루프 — 에는 영향이 없었다.
--  정상 브라우저는 XFF 를 안 보낸다. 그래도 근거 없는 단정이 남는 건 별개 문제다.)
--
-- 같은 방식으로 다른 헤더도 재 봤다:
--
--   헤더                            위조 시도 결과
--   ------------------------------  ------------------------------------------
--   x-forwarded-for                 통과 — 맨 왼쪽이 공격자 값
--   x-real-ip / sb-forwarded-for    무시됨(엣지가 걷어내고 실제 IP 유지)
--   cf-connecting-ip                **엣지가 요청 자체를 거부**(Cloudflare 1000)
--
-- cf-connecting-ip 는 Cloudflare 가 채우고, 클라이언트가 실어 보내면 DB 까지 오지도
-- 못한다. Supabase REST 앞단이 Cloudflare 이므로 이 헤더를 신뢰 출처로 쓴다.
--
-- 헤더가 없으면 XFF 로 폴백하지 않는다 — 폴백이 곧 우회로가 된다. 공용 'cerr:anon'
-- 버킷으로 떨어뜨리고 2단 전역 300/분이 받는다.

create or replace function public.record_client_error(
  p_where    text,
  p_message  text,
  p_stack    text  default null,
  p_platform text  default null,
  p_release  text  default null,
  p_extra    jsonb default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := app.uid();
  v_ip    text;
  v_key   text;
  v_extra jsonb;
begin
  if coalesce(p_where, '') = '' or coalesce(p_message, '') = '' then
    return; -- 조용히 무시(오류 보고가 예외를 던지면 안 된다)
  end if;

  -- 1단: 개별 상한 30/분.
  -- 익명 식별은 cf-connecting-ip 로만 한다. x-forwarded-for 는 맨 왼쪽이 클라이언트
  -- 주장값이라 못 쓴다(위조 시 버킷이 무한 생성). 헤더가 없으면 폴백하지 않고
  -- 공용 버킷으로 떨어뜨린다 — 폴백이 곧 우회로다.
  if v_uid is not null then
    v_key := 'cerr:' || v_uid::text;
  else
    v_ip := btrim(coalesce(
              (nullif(current_setting('request.headers', true), '')::jsonb
                 ->> 'cf-connecting-ip'), ''));
    v_key := case
               when v_ip <> '' then 'cerr:ip:' || md5(v_ip)
               else 'cerr:anon'
             end;
  end if;

  if not public.rate_limit_hit(v_key, 30, 60) then
    return;
  end if;

  -- 2단: 익명 전역 안전판. 1단을 통과한 요청만 카운트하므로 한 소스가
  -- 전역 예산을 독식하지 못한다(개별 상한 30 이 먼저 걸린다).
  if v_uid is null and not public.rate_limit_hit('cerr:anon:all', 300, 60) then
    return;
  end if;

  -- 과대 페이로드는 버리지 않고 **잘린 사실과 앞부분을 남긴다.**
  v_extra := case
               when p_extra is null then null
               when length(p_extra::text) <= 4000 then p_extra
               else jsonb_build_object(
                      'truncated', true,
                      'original_chars', length(p_extra::text),
                      'preview', left(p_extra::text, 3000))
             end;

  insert into app.client_errors
    (user_id, where_key, message, stack, platform, app_release, extra)
  values
    (v_uid,
     left(p_where, 80),
     left(p_message, 500),
     left(p_stack, 8000),
     left(p_platform, 10),
     left(p_release, 40),
     v_extra);
exception when others then
  return; -- 어떤 이유로든 실패해도 앱에 예외를 돌려주지 않는다
end $$;

comment on function public.record_client_error(text, text, text, text, text, jsonb) is
  '클라이언트 오류 수집(0031). anon 포함 공개 — 레이트리밋·길이 제한·예외 삼킴이 전제. 레이트리밋 2단: 개별 30/분(로그인=계정, 익명=cf-connecting-ip) + 익명 전역 300/분.';

notify pgrst, 'reload schema';
