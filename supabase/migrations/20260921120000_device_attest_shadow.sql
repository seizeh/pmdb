-- 기기 증명(App Attest / Play Integrity) 섀도 인프라 — 보안설계 v9.2 §7.5 1단계
--
-- 좌표(lat/lng/accuracy/isMocked)는 클라이언트 자기신고 값이라 직접 POST 로 위조
-- 가능하다(0017 §10 보강 계획). 기기 증명은 "미변조 정품 앱이 정품 기기에서 보낸
-- 요청"까지를 증명해 그 벡터를 좁힌다 — 좌표의 참을 증명하는 것은 아니다.
--
-- 이 마이그레이션은 **섀도 단계의 기록 인프라만** 만든다. 판정은 Edge(_shared/attest.ts)
-- 가 하고, 실패해도 거절하지 않는다(측정 전 하드 리젝 금지 — frames_from_video 관례).
-- 강제 전환은 정상 실패율 측정 후 별도 마이그레이션 없이 Edge 코드 상수로 한다.
--
-- 테이블 3종(app — PostgREST 미노출 + 무그랜트 + RLS 벨트, t28):
--   device_attest_keys  iOS App Attest 키 등록부(공개키·서명 카운터). Android 는 무상태.
--   attest_challenges   iOS 등록(attestKey)용 1회성 챌린지 — 등록 재전송 방지.
--   attest_checks       섀도 측정 원장 — 분모(전 요청)/분자(실패)로 오탐률을 잰다.
--
-- RPC 6종(public — .rpc() 노출 규칙, service_role 전용): app 스키마는 PostgREST 가
-- 노출하지 않아 Edge 가 직접 INSERT 할 수 없다 — signup_user 와 같은 definer 패턴.

-- ── 테이블 ──────────────────────────────────────────────────────────────────

create table app.device_attest_keys (
  user_id      uuid not null references public.users(id) on delete cascade,
  key_id       text not null,            -- Apple keyId(base64) — SHA256(공개키 포인트)
  spki_b64     text not null,            -- 검증용 P-256 공개키(DER SPKI, base64)
  sign_count   bigint not null default 0,-- assertion 단조 증가 카운터(재사용 차단)
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  primary key (user_id, key_id)
);
comment on table app.device_attest_keys is
  'iOS App Attest 키 등록부 — attest-register 가 Apple 루트 CA 체인 검증 후 기록. '
  'assertion 검증은 이 공개키 + sign_count 단조 증가로 한다. Android(Play Integrity)는 무상태라 없음.';

create table app.attest_challenges (
  user_id       uuid primary key references public.users(id) on delete cascade,
  challenge_b64 text not null,
  created_at    timestamptz not null default now()
);
comment on table app.attest_challenges is
  'iOS App Attest 등록(attestKey)용 1회성 챌린지 — attest-register 가 발급·소진. TTL 5분.';

create table app.attest_checks (
  id         bigint generated always as identity primary key,
  user_id    uuid,                        -- FK 없음 — 측정 로그(180일 파기), 계정 삭제와 독립
  fn         text not null,               -- 'verify-location' | 'verify-post-photo'
  platform   text not null,               -- 'ios' | 'android' | 'none'
  verdict    text not null,               -- 'pass' | 'fail' | 'absent' | 'skip'
  reason     text,                        -- fail/skip 사유(≤200자)
  created_at timestamptz not null default now()
);
create index attest_checks_created_idx on app.attest_checks (created_at);
comment on table app.attest_checks is
  '기기 증명 섀도 측정 원장 — 강제 전환 판단용. 분모=전 요청, 분자=verdict=fail. '
  '헤더 미첨부(absent)는 구클라이언트 비율, skip 은 시크릿 미설정 등 판정 불가. 180일 파기(cron).';

-- app 스키마 RLS 벨트(t28) — 정책 0 = 실수 그랜트 보험.
alter table app.device_attest_keys enable row level security;
alter table app.attest_challenges  enable row level security;
alter table app.attest_checks      enable row level security;

-- ── RPC (service_role 전용) ─────────────────────────────────────────────────

-- 등록 챌린지 저장(사용자당 1개 — 새 요청이 이전 것을 덮는다).
create or replace function public.attest_challenge_put(p_user uuid, p_challenge_b64 text)
returns void
language sql security definer set search_path = ''
as $$
  insert into app.attest_challenges (user_id, challenge_b64)
  values (p_user, p_challenge_b64)
  on conflict (user_id) do update
    set challenge_b64 = excluded.challenge_b64, created_at = now();
$$;

-- 등록 챌린지 소진 — 신선하면 값을 돌려주며 삭제, 만료·부재면 null(행은 어차피 삭제).
create or replace function public.attest_challenge_take(p_user uuid, p_max_age_sec int default 300)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_challenge text; v_at timestamptz;
begin
  delete from app.attest_challenges
   where user_id = p_user
  returning challenge_b64, created_at into v_challenge, v_at;
  if v_challenge is null or v_at < now() - make_interval(secs => p_max_age_sec) then
    return null;
  end if;
  return v_challenge;
end;
$$;

-- iOS 키 등록 — 같은 키 재등록은 no-op(카운터 보존). 사용자당 20키 상한(기기·재설치
-- 누적 대비 — 초과 시 가장 오래 안 쓴 키부터 정리).
create or replace function public.attest_key_register(p_user uuid, p_key_id text, p_spki_b64 text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  insert into app.device_attest_keys (user_id, key_id, spki_b64)
  values (p_user, p_key_id, p_spki_b64)
  on conflict (user_id, key_id) do nothing;
  delete from app.device_attest_keys k
   where k.user_id = p_user
     and k.key_id in (
       select key_id from app.device_attest_keys
        where user_id = p_user
        order by coalesce(last_used_at, created_at) desc
        offset 20);
end;
$$;

create or replace function public.attest_key_get(p_user uuid, p_key_id text)
returns table (spki_b64 text, sign_count bigint)
language sql security definer set search_path = ''
as $$
  select k.spki_b64, k.sign_count
    from app.device_attest_keys k
   where k.user_id = p_user and k.key_id = p_key_id;
$$;

-- assertion 통과 후 카운터 전진(단조 — 되감기 불가).
create or replace function public.attest_key_bump(p_user uuid, p_key_id text, p_count bigint)
returns void
language sql security definer set search_path = ''
as $$
  update app.device_attest_keys
     set sign_count = greatest(sign_count, p_count), last_used_at = now()
   where user_id = p_user and key_id = p_key_id;
$$;

-- 섀도 측정 기록 — 실패가 본 흐름을 깨면 안 되므로 호출부(Edge)가 예외를 삼킨다.
create or replace function public.attest_check_log(
  p_user uuid, p_fn text, p_platform text, p_verdict text, p_reason text default null)
returns void
language sql security definer set search_path = ''
as $$
  insert into app.attest_checks (user_id, fn, platform, verdict, reason)
  values (p_user, p_fn, p_platform, p_verdict, left(p_reason, 200));
$$;

-- 권한: service_role 전용(무인증·클라이언트 실행 차단 — signup_user 패턴).
revoke all on function public.attest_challenge_put(uuid, text) from public, anon, authenticated;
revoke all on function public.attest_challenge_take(uuid, int) from public, anon, authenticated;
revoke all on function public.attest_key_register(uuid, text, text) from public, anon, authenticated;
revoke all on function public.attest_key_get(uuid, text) from public, anon, authenticated;
revoke all on function public.attest_key_bump(uuid, text, bigint) from public, anon, authenticated;
revoke all on function public.attest_check_log(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.attest_challenge_put(uuid, text) to service_role;
grant execute on function public.attest_challenge_take(uuid, int) to service_role;
grant execute on function public.attest_key_register(uuid, text, text) to service_role;
grant execute on function public.attest_key_get(uuid, text) to service_role;
grant execute on function public.attest_key_bump(uuid, text, bigint) to service_role;
grant execute on function public.attest_check_log(uuid, text, text, text, text) to service_role;

-- ── 파기 크론 — 측정 로그 180일, 미소진 챌린지 1시간 ──────────────────────────
do $$
begin
  if exists (select 1 from cron.job where jobname = 'attest-maintenance') then
    perform cron.unschedule('attest-maintenance');
  end if;
end $$;
select cron.schedule('attest-maintenance', '10 19 * * *', $$
  delete from app.attest_checks where created_at < now() - interval '180 days';
  delete from app.attest_challenges where created_at < now() - interval '1 hour';
$$);
