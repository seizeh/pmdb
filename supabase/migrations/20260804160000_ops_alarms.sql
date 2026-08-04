-- 운영 알람 — 모으기만 하고 알려 주지 않던 것을 알리게 한다 (0031 §6.1 · 0032 §9.3).
--
-- 지금까지의 상태: client_errors 는 쌓이고 관리자 화면도 있는데 **누가 그 화면을 열어야**
-- 안다. 레이트리밋은 발동해도 아무 흔적이 없다(rate_limit_hit 이 카운트만 세고 버린다).
-- 출시 후에는 이게 "문제가 있었는지조차 모름" 으로 직결된다.
--
-- 전달 경로는 이미 있는 것을 쓴다 — notifications INSERT → on_notification_push →
-- Edge Function → FCM. 새 외부 서비스가 없으니 처리방침도 그대로다.
--
-- ⚠️ 이 경로의 한계를 분명히 해 둔다: **푸시 파이프라인이 죽으면 푸시로 알리는 알람도
--    못 온다.** 그래서 알람은 세 군데에 남는다 — app.ops_alarms(이력) · notifications
--    (앱 안 목록) · 푸시. 앞의 둘은 파이프라인과 무관하게 남고, 푸시 실패 자체도
--    알람 조건에 넣었다(다음 스윕에서 앱 안 알림으로는 뜬다).

-- ── 1. 설정 ────────────────────────────────────────────────────────────────
-- 임계값을 코드가 아니라 DB 에 두는 이유: 출시 직후 트래픽을 모르는 상태에서 고른
-- 숫자라 반드시 조정하게 되는데, 그때마다 마이그레이션을 치고 싶지 않다.
-- push_config·care_config 와 같은 boolean 싱글턴 규약을 따른다.
create table if not exists app.ops_alarm_config (
  id                    boolean primary key default true check (id),
  enabled               boolean not null default true,
  window_minutes        integer not null default 15  check (window_minutes between 1 and 1440),
  cooldown_minutes      integer not null default 60  check (cooldown_minutes between 1 and 10080),
  client_error_per_key  integer not null default 20  check (client_error_per_key > 0),
  client_error_total    integer not null default 100 check (client_error_total > 0),
  rate_limit_trips      integer not null default 100 check (rate_limit_trips > 0),
  push_failed           integer not null default 20  check (push_failed > 0),
  cron_failed           integer not null default 1   check (cron_failed > 0),
  purge_overdue_hours   integer not null default 24  check (purge_overdue_hours > 0)
);
insert into app.ops_alarm_config (id) values (true) on conflict (id) do nothing;

-- ── 2. 레이트리밋 발동 기록 ────────────────────────────────────────────────
-- 분 단위로 접어서 센다. 공격 중에는 발동이 초당 수백 건이 될 수 있는데, 발동마다
-- 한 행이면 관측하려다 테이블을 채운다. (family, 분) 으로 접으면 행 수가
-- 15개 계열 × 분 으로 묶인다.
--
-- family = 키의 첫 토큰(`login:ip:1.2.3.4` → `login`). 개별 식별자(uid·전화·IP)는
-- **일부러 버린다** — 알람은 "어느 계열이 얼마나 막혔나" 를 답하면 되고, 누가
-- 막혔는지까지 남기면 그 자체가 보관할 이유 없는 개인정보가 된다.
create table if not exists app.rate_limit_trips (
  family      text        not null,
  minute      timestamptz not null,
  trips       integer     not null default 0,
  primary key (family, minute)
);

-- rate_limit_hit — 초과했을 때만 기록을 남기도록 한 줄 추가한다.
-- 나머지는 운영 현재 정의 그대로다.
create or replace function public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_win bigint := floor(extract(epoch from now()) / greatest(p_window_seconds, 1));
  v_bucket text := p_key || ':' || v_win;
  v_count integer;
begin
  if random() < 0.02 then
    delete from app.rate_limits where expires_at < now();
  end if;
  insert into app.rate_limits(bucket, count, expires_at)
  values (v_bucket, 1, now() + make_interval(secs => p_window_seconds))
  on conflict (bucket) do update set count = app.rate_limits.count + 1
  returning count into v_count;

  if v_count > p_max then
    -- 관측이 제한기를 죽이면 안 된다. 기록이 실패해도 판정은 그대로 나간다.
    begin
      insert into app.rate_limit_trips (family, minute, trips)
      values (split_part(p_key, ':', 1), date_trunc('minute', now()), 1)
      on conflict (family, minute) do update
        set trips = app.rate_limit_trips.trips + 1;
    exception when others then
      null;
    end;
  end if;

  return v_count <= p_max;
end $function$;

-- ── 3. 알람 이력 ───────────────────────────────────────────────────────────
create table if not exists app.ops_alarms (
  id        bigint generated always as identity primary key,
  alarm_key text        not null,
  title     text        not null,
  body      text        not null,
  detail    jsonb,
  fired_at  timestamptz not null default now()
);
create index if not exists ops_alarms_key_at_idx on app.ops_alarms (alarm_key, fired_at desc);
create index if not exists ops_alarms_at_idx     on app.ops_alarms (fired_at desc);
create index if not exists rate_limit_trips_minute_idx on app.rate_limit_trips (minute);

-- ── 4. 발사 ────────────────────────────────────────────────────────────────
-- 쿨다운을 여기 한 곳에 둔다. 조건마다 따로 두면 하나를 고칠 때 나머지가 어긋난다.
-- 같은 alarm_key 는 쿨다운 안에 다시 울리지 않는다 — 급증은 대개 몇 분간 이어지는데
-- 5분마다 같은 알람이 오면 사람은 알림을 끄고, 그럼 관측 장치가 없는 것과 같아진다.
create or replace function app.ops_alarm_fire(
  p_key text, p_cooldown_min integer,
  p_title text, p_body text, p_detail jsonb
) returns integer
language plpgsql
security definer
set search_path to ''
as $$
begin
  if exists (
    select 1 from app.ops_alarms a
     where a.alarm_key = p_key
       and a.fired_at > now() - make_interval(mins => p_cooldown_min)
  ) then
    return 0;
  end if;

  insert into app.ops_alarms (alarm_key, title, body, detail)
  values (p_key, p_title, p_body, p_detail);

  -- 활성 관리자 전원에게. actor_user_id 가 없으므로 차단 필터(§8.9)에 걸리지 않는다.
  insert into public.notifications
    (user_id, notification_type, is_system, title, body)
  select u.id, 'system_notice', true, p_title, p_body
    from public.users u
   where u.user_type = 'admin' and u.status = 'active';

  return 1;
end $$;

-- ── 5. 스윕 ────────────────────────────────────────────────────────────────
create or replace function app.ops_alarm_sweep()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  c      app.ops_alarm_config%rowtype;
  v_from timestamptz;
  v_n    integer := 0;
  v_cnt  bigint;
  r      record;
begin
  select * into c from app.ops_alarm_config limit 1;
  -- 설정 행이 없으면 **조용히 꺼지는 대신 기본값으로 되살린다.**
  -- 설정 INSERT 는 스키마가 아니라 데이터라 pg_dump --schema-only 에 안 담긴다 —
  -- 스냅샷으로 세운 DB(테스트·재해복구)에서는 이 테이블이 비어 있다. 거기서
  -- "행이 없으니 return 0" 이면 알람이 죽은 걸 알람이 알려 줄 수 없다.
  if not found then
    insert into app.ops_alarm_config (id) values (true) on conflict (id) do nothing;
    select * into c from app.ops_alarm_config limit 1;
  end if;
  if not c.enabled then
    return 0;
  end if;
  v_from := now() - make_interval(mins => c.window_minutes);

  -- ① 앱 오류 급증 — 지점(where_key)별로 본다.
  --    총량으로만 보면 여러 지점의 평상시 잡음이 합쳐져 임계를 넘고, 정작 한 지점이
  --    터진 건 못 잡는다. 알람은 "어디가" 를 답해야 쓸모가 있다.
  for r in
    select e.where_key as k, count(*) as n
      from app.client_errors e
     where e.created_at > v_from
     group by 1
    having count(*) >= c.client_error_per_key
  loop
    v_n := v_n + app.ops_alarm_fire(
      'client_error:' || r.k, c.cooldown_minutes,
      '앱 오류 급증',
      r.k || ' 에서 ' || r.n || '건 (최근 ' || c.window_minutes || '분)',
      jsonb_build_object('where', r.k, 'count', r.n, 'window_min', c.window_minutes));
  end loop;

  -- ①-2 총량. 지점별만 보면 **넓게 깨진 경우를 놓친다** — 서버가 죽으면 모든 화면이
  --     조금씩 실패해서 지점별로는 임계에 못 미치는데 총량은 폭증한다.
  select count(*) into v_cnt
    from app.client_errors e
   where e.created_at > v_from;
  if v_cnt >= c.client_error_total then
    v_n := v_n + app.ops_alarm_fire(
      'client_error_total', c.cooldown_minutes,
      '앱 오류 총량 급증',
      v_cnt || '건 (최근 ' || c.window_minutes || '분, 지점 무관)',
      jsonb_build_object('count', v_cnt, 'window_min', c.window_minutes));
  end if;

  -- ② 레이트리밋 발동 — 계열별.
  for r in
    select t.family as k, sum(t.trips) as n
      from app.rate_limit_trips t
     where t.minute > v_from
     group by 1
    having sum(t.trips) >= c.rate_limit_trips
  loop
    v_n := v_n + app.ops_alarm_fire(
      'ratelimit:' || r.k, c.cooldown_minutes,
      '레이트리밋 다발',
      r.k || ' 계열이 ' || r.n || '회 차단됨 (최근 ' || c.window_minutes || '분)',
      jsonb_build_object('family', r.k, 'trips', r.n, 'window_min', c.window_minutes));
  end loop;

  -- ③ 푸시 발송 실패.
  select count(*) into v_cnt
    from public.notifications n
   where n.push_status = 'failed'
     and n.updated_at > v_from;
  if v_cnt >= c.push_failed then
    v_n := v_n + app.ops_alarm_fire(
      'push_failed', c.cooldown_minutes,
      '푸시 발송 실패 다발',
      v_cnt || '건 실패 (최근 ' || c.window_minutes || '분)',
      jsonb_build_object('count', v_cnt, 'window_min', c.window_minutes));
  end if;

  -- ④ 크론 실패. 'running' 은 진행 중이므로 세지 않는다.
  --    이 스윕 자신이 실패하면 이 조건도 못 돈다 — 다음 회차가 지난 실패를 잡는다.
  --
  --    to_regclass 로 먼저 확인하는 이유: pg_cron 은 **운영에만 있다**. pgTAP CI 는
  --    prelude + schema.sql(= -n public -n app 덤프)만 복원하므로 cron 스키마가 없고,
  --    그냥 참조하면 이 함수는 그 환경에서 통째로 못 돈다 — 알람을 검증하려고
  --    부르는 순간 터진다. 없으면 이 조건만 건너뛴다.
  v_cnt := 0;
  if to_regclass('cron.job_run_details') is not null then
    select count(*) into v_cnt
      from cron.job_run_details d
     where d.status = 'failed'
       and d.end_time > v_from;
  end if;
  if v_cnt >= c.cron_failed then
    v_n := v_n + app.ops_alarm_fire(
      'cron_failed', c.cooldown_minutes,
      '크론 잡 실패',
      v_cnt || '건 실패 (최근 ' || c.window_minutes || '분)',
      jsonb_build_object('count', v_cnt, 'window_min', c.window_minutes));
  end if;

  -- ⑤ 증빙 파기 적체 — 법정 의무가 미이행인 상태이므로 급증이 아니라 **1건이라도** 본다.
  select count(*) into v_cnt
    from app.business_doc_purge_queue q
   where q.purged_at is null
     and q.purge_after < now() - make_interval(hours => c.purge_overdue_hours);
  if v_cnt > 0 then
    v_n := v_n + app.ops_alarm_fire(
      'purge_overdue', c.cooldown_minutes,
      '증빙 파기 지연',
      v_cnt || '건이 ' || c.purge_overdue_hours || '시간 넘게 파기되지 않음',
      jsonb_build_object('count', v_cnt, 'overdue_hours', c.purge_overdue_hours));
  end if;

  return v_n;
end $$;

revoke all on function app.ops_alarm_fire(text, integer, text, text, jsonb) from public, anon, authenticated;
revoke all on function app.ops_alarm_sweep() from public, anon, authenticated;

-- ── 6. 관리자 조회 ─────────────────────────────────────────────────────────
-- 푸시를 못 받았거나 지웠을 때 되짚을 창구. app 스키마는 PostgREST 미노출이라 RPC 경유.
create or replace function public.admin_ops_alarms(p_limit integer default 50, p_offset integer default 0)
returns table (id bigint, alarm_key text, title text, body text, detail jsonb, fired_at timestamptz)
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select a.id, a.alarm_key, a.title, a.body, a.detail, a.fired_at
    from app.ops_alarms a
   order by a.fired_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end $$;

revoke all on function public.admin_ops_alarms(integer, integer) from public, anon;
grant execute on function public.admin_ops_alarms(integer, integer) to authenticated, service_role;

-- ── 7. 보존 ────────────────────────────────────────────────────────────────
-- 운영 현재 정의에 두 줄을 더한 것이다(그 외는 손대지 않았다).
create or replace function app.cleanup_retention()
returns void
language sql
security definer
set search_path to ''
as $function$
  delete from public.phone_verifications where created_at < now() - interval '1 day';

  delete from public.location_verifications where created_at < now() - interval '6 months';

  delete from public.photo_verifications pv
   where pv.created_at < now() - interval '6 months'
     and not exists (select 1 from public.pets  p  where p.ai_ref_verification_id = pv.id)
     and not exists (select 1 from public.posts po where po.photo_verification_id = pv.id);

  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where created_at < now() - interval '6 months'
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);

  update public.posts p
     set actual_lat = null, actual_lng = null
   where (p.visibility_status like 'deleted_%'
          or exists (select 1 from public.users u where u.id = p.user_id and u.status = 'deleted'))
     and (p.actual_lat is not null or p.actual_lng is not null);

  delete from public.post_views where viewed_at < now() - interval '3 months';

  delete from app.auth_logs where created_at < now() - interval '3 months';

  delete from app.location_usage_logs where used_at < now() - interval '6 months';

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '30 days'
     and exists (select 1 from public.users u
                  where u.id = bp.user_id and u.status = 'deleted');

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '6 months';

  delete from app.client_errors where created_at < now() - interval '30 days';

  delete from public.chat_messages
   where is_deleted = true
     and coalesce(deleted_at, updated_at, created_at) < now() - interval '30 days';

  -- ▼ 간이 후기 계정: 남은 후기가 없으면 전화번호 파기(「간이 후기 이용조건」 §3).
  --   후기를 다 지운 경우와, 인증만 받고 작성하지 않은 경우를 한 규칙이 함께 덮는다.
  update public.users u
     set phone = null,
         phone_verified = false
   where u.status = 'lite'
     and u.phone is not null
     and u.created_at < now() - interval '1 day'
     and not exists (
       select 1 from public.facility_reviews r where r.user_id = u.id);

  -- ▼ 관측 데이터. client_errors 와 같은 30일로 맞춘다(같이 보게 되는 자료라 기간이
  --   다르면 "왜 이때는 알람이 없지" 가 보존 차이인지 실제인지 구분이 안 된다).
  delete from app.ops_alarms       where fired_at < now() - interval '30 days';
  delete from app.rate_limit_trips where minute   < now() - interval '30 days';
$function$;

-- ── 8. 스케줄 ──────────────────────────────────────────────────────────────
-- 5분. 창(15분)보다 짧아야 급증이 창 밖으로 빠져나가기 전에 잡힌다.
do $$ begin
  if exists (select 1 from cron.job where jobname = 'ops-alarm-sweep') then
    perform cron.unschedule('ops-alarm-sweep');
  end if;
end $$;
select cron.schedule('ops-alarm-sweep', '*/5 * * * *', $$select app.ops_alarm_sweep();$$);
