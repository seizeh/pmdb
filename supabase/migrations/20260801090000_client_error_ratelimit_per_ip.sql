-- record_client_error 보완 두 가지.
--
-- (1) 익명 레이트리밋이 **자기 텔레메트리를 스스로 가릴 수 있었다.**
--
--     기존: 익명 전체가 단일 버킷 300/분.
--     웹은 비로그인이 주 진입로다. 방문자 한 명의 브라우저에서 오류 루프가 돌면
--     그 사람이 300/분을 혼자 태우고, 그동안 **다른 모든 방문자의 오류가 조용히
--     버려진다.** 하필 제일 알고 싶은 순간(무언가 크게 깨진 순간)에 눈이 먼다.
--
--     "홍수를 막는다" 와 "홍수가 나면 나머지가 안 보인다" 는 다른 얘기다.
--     app.post_views 가 이미 ip_hash 로 비로그인을 가르고 있으므로 같은 축을 쓴다.
--
--     이제 두 단으로 건다:
--       1단 개별  — 로그인 계정별 / 익명 IP별 30분당... 이 아니라 30건/분
--       2단 전역  — 익명 합산 300/분 (분산 소스發 홍수용 안전판)
--     **개별이 먼저 걸리게** 순서를 잡는 게 요점이다. 1단에서 막히면 2단 카운터를
--     올리지 않으므로, 폭주하는 한 명이 전역 예산을 30건 넘게 태울 수 없다.
--
--     IP 는 PostgREST 요청 헤더에서 서버가 직접 뽑는다(클라이언트가 못 속인다).
--     저장하지 않는다 — md5 는 app.rate_limits 의 60초짜리 버킷 키로만 쓰이고
--     만료되면 사라진다. app.client_errors 에는 IP 관련 컬럼이 없다.
--
-- (2) extra 가 4,000자를 넘으면 통째로 null 이었다.
--     컨텍스트가 큰 오류가 대개 제일 이상한 오류인데 그때 컨텍스트를 전부 잃는다.
--     잘린 사실과 앞부분을 남긴다.

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
  v_ok    boolean;
begin
  if coalesce(p_where, '') = '' or coalesce(p_message, '') = '' then
    return; -- 조용히 무시(오류 보고가 예외를 던지면 안 된다)
  end if;

  -- 1단: 개별 상한 30/분.
  -- 익명은 x-forwarded-for 의 첫 항목(원 클라이언트)으로 가른다. 헤더가 없거나
  -- 비어 있으면(직접 접속·프록시 이상) 공용 'anon' 버킷으로 떨어진다.
  if v_uid is not null then
    v_key := 'cerr:' || v_uid::text;
  else
    v_ip := btrim(split_part(
              coalesce(
                (nullif(current_setting('request.headers', true), '')::jsonb
                   ->> 'x-forwarded-for'),
                ''),
              ',', 1));
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
  '클라이언트 오류 수집(0031). anon 포함 공개 — 레이트리밋·길이 제한·예외 삼킴이 전제. 레이트리밋 2단: 개별 30/분(로그인=계정, 익명=IP) + 익명 전역 300/분.';

-- 시그니처가 그대로라 GRANT 는 유지되지만, 재정의 후 PostgREST 스키마 캐시를 깨운다.
notify pgrst, 'reload schema';
