-- 위치정보 이용·제공사실 확인자료 자동 기록·파기 (위치정보법 제16조 제2항,
-- 위치기반서비스 이용약관 제8조, 사업계획서 §3.4 / 운영점검주기 문서 §1 이행).
--
-- 약관 제8조②가 약속한 확인자료 항목(이용자 식별정보·이용 일시·이용 목적·제공받은 자)을
-- 개인위치정보가 서버에 저장되는 3개 지점의 AFTER INSERT 트리거로 자동 기록한다:
--   1) location_verifications — 활동지역 인증(GPS 검증)
--   2) photo_verifications(촬영 좌표 있는 행) — 게시글 사진 촬영위치 검증
--   3) posts(작성 좌표 있는 행) — 게시글 작성 위치 기록
-- 시설 검색(facilities_search)의 좌표 파라미터는 거리 정렬에만 일시 이용되고 저장·식별 연계가
-- 없어(STABLE 함수, uid 미사용) 확인자료 기록 대상에서 제외한다.
--
-- FK 를 두지 않는 이유: 탈퇴(격리) 후에도 확인자료는 법정 기간(6개월) 분리 보존 후 파기해야
-- 한다(사업계획서 §3.4). users 행 삭제에 연동해 지우면 안 된다.
create table if not exists app.location_usage_logs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,            -- 이용자 식별정보 (FK 없음 — 탈퇴 후 분리 보존)
  purpose     text not null,            -- 이용·제공 목적
  provided_to text,                     -- 제공받은 자(제3자 제공 시 — 현재 서비스는 제공 없음)
  used_at     timestamptz not null default now()  -- 이용·제공 일시
);
create index if not exists idx_location_usage_logs_used
  on app.location_usage_logs (used_at);
create index if not exists idx_location_usage_logs_user
  on app.location_usage_logs (user_id, used_at desc);
-- 정책 없는 RLS = API 직접 접근 차단(app 스키마는 PostgREST 미노출이지만 이중 방어).
alter table app.location_usage_logs enable row level security;

comment on table app.location_usage_logs is
  '위치정보 이용·제공사실 확인자료 (위치정보법 제16조 제2항, 6개월 보존 후 파기)';

-- 공용 트리거 함수: TG_ARGV[0] = 이용 목적. 기록 대상 테이블 INSERT 는 모두
-- SECURITY DEFINER RPC(record_location_verification / record_photo_verification /
-- create_post_verified) 경유이지만, 함수 자체도 definer 로 두어 실행 컨텍스트와 무관하게 기록한다.
create or replace function app.tg_log_location_usage()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  insert into app.location_usage_logs (user_id, purpose)
  values (new.user_id, tg_argv[0]);
  return null;
end;
$function$;
revoke all on function app.tg_log_location_usage() from public, anon, authenticated;

drop trigger if exists log_location_usage on public.location_verifications;
create trigger log_location_usage
  after insert on public.location_verifications
  for each row
  execute function app.tg_log_location_usage('활동지역 인증(GPS 검증)');

drop trigger if exists log_location_usage on public.photo_verifications;
create trigger log_location_usage
  after insert on public.photo_verifications
  for each row
  when (new.shot_lat is not null or new.shot_lng is not null)
  execute function app.tg_log_location_usage('게시글 사진 촬영위치 검증');

drop trigger if exists log_location_usage on public.posts;
create trigger log_location_usage
  after insert on public.posts
  for each row
  when (new.actual_lat is not null or new.actual_lng is not null)
  execute function app.tg_log_location_usage('게시글 작성 위치 기록');

-- 백필: 트리거 도입 이전의 이용 사실도 원본 테이블 created_at 기준으로 소급 기록
-- (서비스 개시 2026-05 이라 전 구간이 6개월 이내 → 전량 유효).
insert into app.location_usage_logs (user_id, purpose, used_at)
select user_id, '활동지역 인증(GPS 검증)', created_at
  from public.location_verifications
union all
select user_id, '게시글 사진 촬영위치 검증', created_at
  from public.photo_verifications
 where shot_lat is not null or shot_lng is not null
union all
select user_id, '게시글 작성 위치 기록', created_at
  from public.posts
 where actual_lat is not null or actual_lng is not null;

-- 파기 배치 편입: 6개월 경과분 파기 (법정 '6개월 이상 보존' 충족 후 지체 없이 파기).
-- 기존 정리 항목은 20260711065201_auth_logs 버전 그대로 유지.
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
  -- 위치정보 이용·제공사실 확인자료: 6개월 보존 후 파기 (위치정보법 제16조 제2항)
  delete from app.location_usage_logs where used_at < now() - interval '6 months';
$function$;
revoke all on function app.cleanup_retention() from public, anon, authenticated;

-- 열람청구권 대응 (약관 제10조): 이용자가 고객센터로 열람을 요구하면 관리자가 조회해 회신.
-- is_admin 게이트 SECURITY DEFINER RPC 컨벤션(admin_list_reports 등)과 동일.
create or replace function public.admin_location_usage_logs(
  p_user   uuid,
  p_limit  int default 100,
  p_offset int default 0
)
returns table (user_id uuid, purpose text, provided_to text, used_at timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  return query
  select l.user_id, l.purpose, l.provided_to, l.used_at
    from app.location_usage_logs l
   where l.user_id = p_user
   order by l.used_at desc
   limit greatest(1, least(coalesce(p_limit,100), 500))
   offset greatest(0, coalesce(p_offset,0));
end;
$function$;
revoke all on function public.admin_location_usage_logs(uuid,int,int) from public, anon;
grant execute on function public.admin_location_usage_logs(uuid,int,int) to authenticated;
