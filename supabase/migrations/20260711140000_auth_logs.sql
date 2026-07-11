-- 로그인 접속 로그 (개인정보 처리방침 §3: 접속 로그·IP 3개월 보존). IP 는 SHA-256 해시로만 저장.
-- 로그인 엣지펑션이 성공 시 public.record_auth_log() 로 1행 기록하고, retention-purge 배치가
-- 3개월 경과분을 파기한다. 처리방침이 약속한 접속 로그 보존을 실제로 이행하기 위한 저장소.
create table if not exists app.auth_logs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  ip_hash    text,
  created_at timestamptz not null default now()
);
create index if not exists idx_auth_logs_created on app.auth_logs (created_at);
-- 정책 없는 RLS = API 직접 접근 차단(정의자 RPC/service_role 만 기록·조회).
alter table app.auth_logs enable row level security;

-- 로그인 성공 시 엣지펑션(service_role)이 호출 — 접속 로그 1행 기록.
create or replace function public.record_auth_log(p_user uuid, p_ip_hash text)
returns void
language sql
security definer
set search_path to ''
as $function$
  insert into app.auth_logs (user_id, ip_hash) values (p_user, nullif(p_ip_hash, ''));
$function$;
revoke all on function public.record_auth_log(uuid, text) from public, anon, authenticated;
grant execute on function public.record_auth_log(uuid, text) to service_role;

-- 파기 배치에 접속 로그 3개월 편입 (기존 정리 항목 유지 + app.auth_logs 추가).
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
$function$;
revoke all on function app.cleanup_retention() from public, anon, authenticated;
