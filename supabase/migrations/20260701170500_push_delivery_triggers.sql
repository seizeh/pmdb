-- 푸시 발송 트리거링: (1) notifications insert 시 즉시 pg_net 으로 send-push 호출(단건, 저지연),
-- (2) pg_cron 매분 스윕(pending 재시도/누락 보완). 둘 다 app.push_config 의 URL+시크릿 사용.
-- send-push 는 PUSH_TRIGGER_SECRET env 미설정 시 503 → 설정 전까지는 발송 없이 pending 유지.

create or replace function app.on_notification_push()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare v_url text; v_secret text;
begin
  if new.push_status = 'pending' and coalesce(new.is_silent, false) = false then
    select function_url, trigger_secret into v_url, v_secret from app.push_config limit 1;
    if v_url is not null then
      perform net.http_post(
        url := v_url,
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
        body := jsonb_build_object('notification_id', new.id)
      );
    end if;
  end if;
  return new;
end $function$;

drop trigger if exists trg_notifications_push on public.notifications;
create trigger trg_notifications_push
  after insert on public.notifications
  for each row execute function app.on_notification_push();

-- 매분 스윕(pending 있을 때만 호출).
do $$ begin
  if exists (select 1 from cron.job where jobname = 'push-sweep') then
    perform cron.unschedule('push-sweep');
  end if;
end $$;
select cron.schedule('push-sweep', '* * * * *', $CRON$
  select net.http_post(
    url := (select function_url from app.push_config),
    headers := jsonb_build_object('Content-Type','application/json','x-push-secret',(select trigger_secret from app.push_config)),
    body := '{}'::jsonb)
  where exists (select 1 from public.notifications where push_status = 'pending');
$CRON$);
