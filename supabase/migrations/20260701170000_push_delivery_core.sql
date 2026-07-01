-- 푸시 발송 파이프라인(사장님 스캐폴딩 완성): device_tokens/notification_preferences/
-- notifications.push_* + mark_push_*(app) 를 실제로 구동하는 발송기(send-push 엣지)용 RPC.
-- 흐름: notifications(pending) → [트리거/크론 pg_net] → send-push 엣지 → push_dispatch_batch
-- 로 클레임(silent/pref_off/no_device 스킵, 나머지 'sending' 전이) → FCM 발송 → push_report
-- 로 sent/failed 기록 + 죽은 토큰 deactivate. (트리거/크론은 별도 마이그레이션에서 엣지 배포 후.)

-- 중복 발송 방지용 중간상태 'sending' 추가(기존 pending/sent/failed/skipped 에 더함).
alter table public.notifications drop constraint if exists notifications_push_status_check;
alter table public.notifications add constraint notifications_push_status_check
  check (push_status::text = any (array['pending','sending','sent','failed','skipped']::text[]));

-- 토큰 upsert(register) 지원용 유니크.
create unique index if not exists device_tokens_token_uq on public.device_tokens(token);

-- 발송기 호출용 설정(단일 행): 엣지 URL + 트리거 시크릿(자동 생성, 엣지 env PUSH_TRIGGER_SECRET 와 일치시킬 것).
create table if not exists app.push_config (
  id             boolean primary key default true,
  function_url   text not null,
  trigger_secret text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  constraint push_config_singleton check (id)
);
insert into app.push_config(id, function_url)
values (true, 'https://vyatppuxmpulqtxevfpk.supabase.co/functions/v1/send-push')
on conflict (id) do nothing;

-- 기기 푸시 토큰 등록/갱신(로그인/토큰갱신 시 앱이 호출). authenticated 전용.
create or replace function public.register_device_token(
  p_token text, p_platform text, p_device_name text default null
) returns void
language plpgsql security definer set search_path to '' as $function$
declare v_uid uuid := app.uid();
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  if p_token is null or length(p_token) < 10 then raise exception 'invalid_token' using errcode='P0001'; end if;
  insert into public.device_tokens(user_id, token, platform, device_name, is_active, failure_count, updated_at)
  values (v_uid, p_token, p_platform, p_device_name, true, 0, now())
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        device_name = coalesce(excluded.device_name, public.device_tokens.device_name),
        is_active = true, failure_count = 0, updated_at = now();
end $function$;

-- 타입별 푸시 수신 설정 확인(설정 행/컬럼 없으면 기본 허용).
create or replace function public._push_pref_allows(p_user uuid, p_type text)
returns boolean language sql stable security definer set search_path to '' as $function$
  select coalesce((
    select case p_type
      when 'chat_message' then chat_message
      when 'post_application' then post_application
      when 'post_comment' then post_comment
      when 'pawing_new_post' then pawing_new_post
      when 'application_accepted' then application_accepted
      when 'review_received' then review_received
      when 'system_notice' then system_notice
      else true
    end
    from public.notification_preferences where user_id = p_user
  ), true)
$function$;

-- 발송 대상 클레임: pending(또는 특정 id) 중 silent/pref_off/no_device 는 즉시 skip 처리,
-- 나머지는 'sending' 으로 전이(중복 방지) 후 토큰과 함께 반환. 5분↑ 좀비 'sending' 은 복구.
create or replace function public.push_dispatch_batch(p_only_id uuid default null, p_limit int default 50)
returns table(notification_id uuid, ntype text, title text, body text, resource_type text, resource_id uuid, tokens jsonb)
language plpgsql security definer set search_path to '' as $function$
declare rec record; v_tokens jsonb;
begin
  update public.notifications set push_status='pending', updated_at=now()
   where push_status='sending' and updated_at < now() - interval '5 minutes';

  for rec in
    select n.id, n.user_id, n.notification_type::text as ntype, n.title, n.body,
           n.resource_type, n.resource_id, coalesce(n.is_silent,false) as is_silent
    from public.notifications n
    where n.push_status='pending' and (p_only_id is null or n.id = p_only_id)
    order by n.created_at
    limit p_limit
    for update of n skip locked
  loop
    if rec.is_silent then perform app.mark_push_skipped(rec.id, 'silent'); continue; end if;
    if not public._push_pref_allows(rec.user_id, rec.ntype) then
      perform app.mark_push_skipped(rec.id, 'pref_off'); continue;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('token', d.token, 'platform', d.platform)), '[]'::jsonb)
      into v_tokens from public.device_tokens d
      where d.user_id = rec.user_id and d.is_active = true;
    if v_tokens = '[]'::jsonb then perform app.mark_push_skipped(rec.id, 'no_device'); continue; end if;
    update public.notifications set push_status='sending', updated_at=now() where id = rec.id;
    notification_id := rec.id; ntype := rec.ntype; title := rec.title; body := rec.body;
    resource_type := rec.resource_type; resource_id := rec.resource_id; tokens := v_tokens;
    return next;
  end loop;
end $function$;

-- 발송 결과 반영: [{notification_id, ok, error?, dead_tokens:[...]}]. 죽은 토큰 비활성 + sent/failed.
create or replace function public.push_report(p_results jsonb)
returns void language plpgsql security definer set search_path to '' as $function$
declare item jsonb; dead text;
begin
  for item in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    for dead in select jsonb_array_elements_text(coalesce(item->'dead_tokens', '[]'::jsonb)) loop
      perform app.deactivate_device_token(dead, 'unregistered');
    end loop;
    if coalesce((item->>'ok')::boolean, false) then
      perform app.mark_push_sent((item->>'notification_id')::uuid);
    else
      perform app.mark_push_failed((item->>'notification_id')::uuid, item->>'error', false, 3::smallint);
    end if;
  end loop;
end $function$;

-- 권한: register 는 authenticated(앱), dispatch/report 는 service_role(엣지) 전용. 내부 헬퍼는 잠금.
revoke all on function public.register_device_token(text,text,text) from public, anon;
grant execute on function public.register_device_token(text,text,text) to authenticated;
revoke all on function public._push_pref_allows(uuid,text) from public, anon, authenticated;
do $$ declare fn text; begin
  foreach fn in array array[
    'public.push_dispatch_batch(uuid,integer)',
    'public.push_report(jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end $$;
