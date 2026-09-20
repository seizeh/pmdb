-- 알람 억제를 관측 가능하게 + 엣지 알람을 원장(ops_alarms)으로 통합
--
-- 종전: ① ops_alarm_fire 는 쿨다운 내 재발화를 무기록으로 삼켰다(return 0) —
-- 30분 내 1회 재발과 폭주가 구분 불가, "알림 억제 = 관측 손실".
-- ② 엣지 alertAdmins 는 발송 시에도 ops_alarms 에 안 쓰고 notifications 만 —
-- 스로틀도 rate_limit_hit 로 별도 구현(2026-08-08 판정 반전 사고가 난 그 이중 경로).
--
-- 변경: 억제 시 최신 행에 fire_count·last_seen_at 갱신(알림 폭주 억제는 유지),
-- 엣지는 public.edge_alert_fire 래퍼(service_role 전용)로 같은 원장을 쓴다.
-- 알림 insert 에 엣지 경로가 갖고 있던 priority high·그룹키를 승계.

alter table app.ops_alarms
  add column last_seen_at timestamptz not null default now(),
  add column fire_count   integer     not null default 1;

comment on column app.ops_alarms.last_seen_at is
  '같은 key 의 마지막 발생 시각(억제 포함) — fired_at 은 알림이 나간 시각';
comment on column app.ops_alarms.fire_count is
  '이 쿨다운 창의 총 발생 횟수(발송 1 + 억제 n). suppressed = fire_count - 1';

create or replace function app.ops_alarm_fire(
  p_key text, p_cooldown_min integer, p_title text, p_body text, p_detail jsonb
) returns integer
language plpgsql security definer set search_path to ''
as $$
begin
  if exists (
    select 1 from app.ops_alarms a
     where a.alarm_key = p_key
       and a.fired_at > now() - make_interval(mins => p_cooldown_min)
  ) then
    -- 억제도 발생이다 — 최신 행에 횟수·시각을 남긴다. 이게 없으면 30분 내
    -- 1회 재발과 29분간 초당 재발이 구분되지 않는다(알림 억제 = 관측 손실).
    -- clock_timestamp(): now() 는 트랜잭션 시각이라 같은 트랜잭션 안의 연속
    -- 발화(pgTAP 포함)에서 fired_at 과 구분이 안 된다 — 실제 경과 시각을 쓴다.
    update app.ops_alarms a
       set fire_count = a.fire_count + 1, last_seen_at = clock_timestamp()
     where a.id = (
       select id from app.ops_alarms
        where alarm_key = p_key order by fired_at desc limit 1);
    return 0;
  end if;

  insert into app.ops_alarms (alarm_key, title, body, detail)
  values (p_key, p_title, p_body, p_detail);

  -- 활성 관리자 전원에게. actor_user_id 가 없으므로 차단 필터(§8.9)에 걸리지 않는다.
  -- priority·그룹키는 엣지 alertAdmins 가 갖고 있던 것을 통합하며 승계(2026-09-21).
  -- ON CONFLICT: notifications_group_uq(미읽음 부분 유니크)와의 충돌 — 같은 알람의
  -- 직전 알림이 아직 미읽음이면 행·푸시를 중복하지 않는다(관측은 원장 fire_count 가
  -- 담당). 종전 엣지 경로는 이 충돌이 조용한 insert 실패였다 — 의도로 승격.
  -- 술어는 인덱스 술어를 그대로 함의해야 중재자 추론이 된다(is_read + group_key not null).
  insert into public.notifications
    (user_id, notification_type, is_system, priority, notification_group_key, title, body)
  select u.id, 'system_notice', true, 'high', 'ops_alarm:' || p_key, p_title, p_body
    from public.users u
   where u.user_type = 'admin' and u.status = 'active'
  on conflict (user_id, notification_group_key)
    where (is_read = false and notification_group_key is not null) do nothing;

  return 1;
end $$;

-- 엣지 함수용 래퍼 — app 스키마는 PostgREST 미노출이라 public 에 필요.
-- 키에 'edge:' 접두로 엣지발 알람을 원장에서 구분한다. 쿨다운 30분(종전 스로틀과 동일).
create function public.edge_alert_fire(
  p_key text, p_title text, p_body text, p_detail jsonb default '{}'::jsonb
) returns integer
language sql security definer set search_path to ''
as $$
  select app.ops_alarm_fire('edge:' || p_key, 30, p_title, p_body, p_detail)
$$;

revoke all on function public.edge_alert_fire(text, text, text, jsonb) from public;
grant execute on function public.edge_alert_fire(text, text, text, jsonb) to service_role;

-- admin_ops_alarms 반환형 확장 — RETURNS TABLE 변경은 replace 불가라 drop 후 재생성.
-- (RPC 섀도잉 규율: 구버전 drop + 재그랜트 + pgrst 리로드)
drop function public.admin_ops_alarms(integer, integer);

create function public.admin_ops_alarms(p_limit integer default 50, p_offset integer default 0)
returns table(
  id bigint, alarm_key text, title text, body text, detail jsonb,
  fired_at timestamp with time zone, last_seen_at timestamp with time zone, fire_count integer
)
language plpgsql security definer set search_path to ''
as $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select a.id, a.alarm_key, a.title, a.body, a.detail, a.fired_at, a.last_seen_at, a.fire_count
    from app.ops_alarms a
   order by a.fired_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end $$;

revoke all on function public.admin_ops_alarms(integer, integer) from public, anon;
grant execute on function public.admin_ops_alarms(integer, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
