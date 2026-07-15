-- 업체 모드의 매칭 흐름 차단 (0026 §5-2 해소).
-- 지원→수락→약속→평가는 실제 만남 전제의 '개인' 활동 — 업체 모드로 지원하면
-- 닉네임(개인 얼굴)이 노출되어 정체성이 섞인다. authored_as 확장 대신
-- 진입 자체를 차단(앱은 일반 모드 전환을 유도, 트리거는 경로 무관 최종 방어선).
create or replace function app.applications_block_business_mode()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare v_mode text;
begin
  select u.active_mode into v_mode
    from public.users u where u.id = new.applicant_id;
  if v_mode = 'business' then
    raise exception 'business_mode_not_allowed' using errcode = 'P0001';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_applications_block_business on public.applications;
create trigger trg_applications_block_business
  before insert on public.applications
  for each row execute function app.applications_block_business_mode();
