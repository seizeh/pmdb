-- cleanup_retention 유실 항목 복원.
-- 20260715090000(business_rows_retention_purge)이 구버전 정의를 베이스로 재정의하면서
-- 20260711140000(auth_logs 3개월)·20260712033510(location_usage_logs 6개월) 파기가
-- 빠졌다 — 처리방침 §3 보존기간 이행 항목이라 즉시 복원한다.
-- (같은 사고 재발 방지: 공유 함수 재정의는 프로덕션 현재 정의를 기준으로 할 것.)
-- 최종 정의 = 기존 전체 + 업체 행 파기 + 채팅 30일 하드삭제 + auth/location 로그 복원.

create or replace function app.cleanup_retention()
returns void
language sql security definer set search_path to ''
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

  -- ▼ 접속 로그 3개월 (20260711140000 — 재정의로 유실됐던 항목 복원)
  delete from app.auth_logs where created_at < now() - interval '3 months';

  -- ▼ 위치 이용·제공 기록 6개월 (20260712033510 — 재정의로 유실됐던 항목 복원)
  delete from app.location_usage_logs where used_at < now() - interval '6 months';

  -- ▼ 업체 인증 행 데이터 파기 (처리방침 §3 — 서류 파일은 purge-business-docs 가 담당)
  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '30 days'
     and exists (select 1 from public.users u
                  where u.id = bp.user_id and u.status = 'deleted');

  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '6 months';

  -- ▼ 삭제된 채팅 메시지: 30일 유예 후 하드 삭제(신고 대응 기간 확보 후 파기)
  delete from public.chat_messages
   where is_deleted = true
     and coalesce(deleted_at, updated_at, created_at) < now() - interval '30 days';
$function$;
