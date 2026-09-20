-- pg_cron dead man's switch — 감시 체인이 자기 장애 영역 밖으로 하트비트를 보낸다
-- (0032 §949 "자기 자신의 부재는 감지할 수 없다" 의 해소)
--
-- 운영 감지는 pg_cron → sweep → ops_alarms → notifications → pg_net → FCM 으로
-- 전부 같은 Supabase 프로젝트 안에 있다 — DB 다운·프로젝트 일시정지·pg_cron/
-- pg_net 사망 어느 것이든 감지 체인이 통째로 같이 죽어 침묵한다. 안에서 밖을
-- 감시할 수는 없으므로 방향을 뒤집는다: 5분마다 밖(healthchecks.io)으로 하트비트을
-- 보내고, 하트비트가 grace 내에 끊기면 **외부**가 운영자에게 알린다.
--
-- 엣지 함수만 죽는 경우(DB 생존)는 이 하트비트가 못 본다 — 별도 층(외부 프로브) 과제.
--
-- ping URL 은 capability 다(아는 사람이 가짜 하트비트로 죽음을 가릴 수 있다) —
-- 공개 저장소에 싣지 않고 push_config 전례대로 싱글턴에 out-of-band 주입.

create table app.heartbeat_config (
  ping_url text not null
);

comment on table app.heartbeat_config is
  'dead man''s switch 하트비트 대상(healthchecks.io) 싱글턴 — 값은 out-of-band 주입';

-- app 스키마 RLS 벨트(t28)
alter table app.heartbeat_config enable row level security;

select cron.schedule(
  'ops-heartbeat',
  '*/5 * * * *',
  $$ select net.http_get(url := (select ping_url from app.heartbeat_config))
     where exists (select 1 from app.heartbeat_config) $$
);
