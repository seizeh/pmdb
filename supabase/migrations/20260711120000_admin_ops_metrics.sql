-- 관리자 운영 지표·비용 RPC (AI 사진인증 / Solapi 문자 / 일일 활성 사용자).
-- 모두 app.is_admin() 게이트 + SECURITY DEFINER(컬럼 권한 우회) + public 스키마(.rpc 노출).
-- 비용은 별도 로그가 없어 "단가 × 건수" 추정치다. 단가는 아래 상수로 조정한다.
--   · Solapi SMS 단문(90byte↓): 1건 ≈ ₩9  (요금제별 상이)
--   · Gemini 2.5 Pro 사진인증(기준프레임 N장 + 촬영 1장 멀티이미지): 1건 ≈ ₩20 (보수적 추정)
-- DAU 는 별도 활동 테이블이 없어, 세션(refresh_tokens 발급) + 주요 콘텐츠 활동을
-- 사용자·일(KST) 단위로 UNION 하여 "그날 활동한 고유 사용자 수"로 산출한다.

create or replace function public.admin_ops_metrics()
returns json
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  c_sms_krw numeric := 9;    -- Solapi SMS 단문 1건 추정 단가(원)
  c_ai_krw  numeric := 20;   -- Gemini 2.5 Pro 사진인증 1건 추정 단가(원)
  tz        text := 'Asia/Seoul';
  today_kst date := (now() at time zone tz)::date;
  v json;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  with pv as (select created_at, result from public.photo_verifications),
  ph as (select created_at from public.phone_verifications),
  act as (
    select user_id,     issued_at  as ts from app.refresh_tokens        where user_id is not null
    union all select sender_id,    created_at from public.chat_messages
    union all select user_id,      created_at from public.comments
    union all select user_id,      created_at from public.posts
    union all select user_id,      created_at from public.post_hearts
    union all select applicant_id, created_at from public.applications
    union all select reviewer_id,  created_at from public.reviews
    union all select follower_id,  created_at from public.pawings
    union all select user_id,      created_at from public.location_verifications
    union all select user_id,      created_at from public.photo_verifications
  ),
  act_kst as (
    select distinct user_id, (ts at time zone tz)::date as d
    from act
    where user_id is not null and ts >= now() - interval '14 days'
  ),
  days as (
    select generate_series(today_kst - 13, today_kst, interval '1 day')::date as d
  ),
  dau_series as (
    select d.d, count(a.user_id) as c
    from days d
    left join act_kst a on a.d = d.d
    group by d.d
    order by d.d
  )
  select json_build_object(
    'unit_cost', json_build_object('sms_krw', c_sms_krw, 'ai_krw', c_ai_krw),
    'ai', json_build_object(
      'total',      (select count(*) from pv),
      'pass',       (select count(*) from pv where result = 'pass'),
      'fail',       (select count(*) from pv where result = 'fail'),
      'today',      (select count(*) from pv where (created_at at time zone tz)::date = today_kst),
      'd7',         (select count(*) from pv where created_at >= now() - interval '7 days'),
      'd30',        (select count(*) from pv where created_at >= now() - interval '30 days'),
      'cost_all',   (select count(*) from pv) * c_ai_krw,
      'cost_today', (select count(*) from pv where (created_at at time zone tz)::date = today_kst) * c_ai_krw,
      'cost_d7',    (select count(*) from pv where created_at >= now() - interval '7 days') * c_ai_krw,
      'cost_d30',   (select count(*) from pv where created_at >= now() - interval '30 days') * c_ai_krw
    ),
    'sms', json_build_object(
      'total',      (select count(*) from ph),
      'today',      (select count(*) from ph where (created_at at time zone tz)::date = today_kst),
      'd7',         (select count(*) from ph where created_at >= now() - interval '7 days'),
      'd30',        (select count(*) from ph where created_at >= now() - interval '30 days'),
      'cost_all',   (select count(*) from ph) * c_sms_krw,
      'cost_today', (select count(*) from ph where (created_at at time zone tz)::date = today_kst) * c_sms_krw,
      'cost_d7',    (select count(*) from ph where created_at >= now() - interval '7 days') * c_sms_krw,
      'cost_d30',   (select count(*) from ph where created_at >= now() - interval '30 days') * c_sms_krw
    ),
    'dau', json_build_object(
      'today',  (select c from dau_series where d = today_kst),
      'series', (select json_agg(json_build_object('d', to_char(d, 'MM-DD'), 'c', c)) from dau_series)
    )
  ) into v;
  return v;
end;
$function$;

grant execute on function public.admin_ops_metrics() to authenticated;

-- AI 사진인증 실패 로그 목록(최신순).
create or replace function public.admin_photo_verification_failures(
  p_limit int default 50, p_offset int default 0)
returns table (
  id uuid,
  created_at timestamptz,
  fail_reason text,
  ai_reason text,
  region_matched boolean,
  ai_match_score numeric,
  purpose text,
  nickname text
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select pv.id, pv.created_at, pv.fail_reason::text, pv.ai_reason::text,
         pv.region_matched, pv.ai_match_score, pv.purpose::text,
         coalesce(u.nickname, '알 수 없음')::text
  from public.photo_verifications pv
  left join public.users u on u.id = pv.user_id
  where pv.result = 'fail'
  order by pv.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end;
$function$;

grant execute on function public.admin_photo_verification_failures(int, int) to authenticated;
