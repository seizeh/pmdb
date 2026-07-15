-- 업체 인증 '행 데이터' 보존기간 파기 (0025 §3.3 · 처리방침 §3 정합).
-- 서류 파일은 파기 큐(purge-business-docs 엣지)가 지우지만, business_profiles 행의
-- 데이터(사업자등록번호·주소·전화·이메일 등)는 rejected 표시 후 무기한 잔존했다 —
-- 처리방침이 약속한 "탈퇴 30일 / 반려 6개월" 파기가 자동화되지 않던 공백을 메운다.
-- app.cleanup_retention() (20260711130000, 매일 03:23 pg_cron) 재정의 — 기존 본문에
-- 업체 블록만 추가. 재신청은 행을 pending 으로 갱신하므로(updated_at 리셋) 안전.
create or replace function app.cleanup_retention()
returns void
language sql
security definer
set search_path to ''
as $function$
  -- 전화 인증코드(OTP): 발급 1일 경과분 파기 (코드 TTL 5분, 데이터 최소화)
  delete from public.phone_verifications where created_at < now() - interval '1 day';

  -- 위치 인증 이력: 6개월 경과분 파기 (들어오는 FK 없음, 지역인증 상태는 users 에 있어 안전)
  delete from public.location_verifications where created_at < now() - interval '6 months';

  -- 사진 인증: 6개월 경과분 중 '미참조' 행만 삭제 (pets/posts FK 위반 방지)
  delete from public.photo_verifications pv
   where pv.created_at < now() - interval '6 months'
     and not exists (select 1 from public.pets  p  where p.ai_ref_verification_id = pv.id)
     and not exists (select 1 from public.posts po where po.photo_verification_id = pv.id);

  -- 참조 중인 사진 인증 행: 촬영 좌표만 파기(스크럽) — 펫·게시글이 계속 참조하는 AI 결과는 보존
  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where created_at < now() - interval '6 months'
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);

  -- 삭제된 게시글 + 탈퇴자(users.status='deleted') 게시글의 실좌표 파기
  update public.posts p
     set actual_lat = null, actual_lng = null
   where (p.visibility_status like 'deleted_%'
          or exists (select 1 from public.users u where u.id = p.user_id and u.status = 'deleted'))
     and (p.actual_lat is not null or p.actual_lng is not null);

  -- 접속 기록(post_views: ip_hash 포함) 3개월 경과분 파기 (처리방침 §3)
  delete from public.post_views where viewed_at < now() - interval '3 months';

  -- ▼ 업체 인증 행 데이터 파기 (처리방침 §3 — 서류 파일은 purge-business-docs 가 담당)
  -- 탈퇴 회원: 30일 후 행 삭제 (withdraw_account 가 rejected 전환·updated_at 갱신)
  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '30 days'
     and exists (select 1 from public.users u
                  where u.id = bp.user_id and u.status = 'deleted');

  -- 반려 후 재신청 없이 6개월 경과: 행 삭제 (재신청 유예 만료)
  delete from public.business_profiles bp
   where bp.status = 'rejected'
     and bp.updated_at < now() - interval '6 months';
$function$;

revoke all on function app.cleanup_retention() from public, anon, authenticated;
