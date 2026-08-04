-- 간이 후기 계정의 전화번호 파기 — 이미 이용자에게 한 약속을 실제로 이행한다.
--
-- ── 무엇이 문제였나 ────────────────────────────────────────────────────────
-- 「간이 후기 이용조건」 §3(2026-07-27 시행, 앱에 게시 중)은 보유·이용 기간을
-- 이렇게 약속하고 있다:
--
--   "작성한 후기가 게시되어 있는 동안. 후기를 모두 삭제하거나 파기를 요청하면
--    지체 없이 파기합니다"
--
-- 그런데 그 파기를 하는 코드가 **어디에도 없었다.** `status='lite'` 를 참조하는
-- 곳은 전부 조회·표시용이고, 정리 배치도 없다. 즉 후기를 다 지워도 전화번호를
-- 가진 users 행이 영구히 남는다.
--
-- 인증만 받고 후기를 안 쓴 경우는 더 나쁘다 — signup-lite 는 토큰 발급 시점에
-- 계정을 만들므로, 작성 화면에서 이탈하면 **아무 목적도 달성하지 못한 전화번호**가
-- 남는다. 개인정보보호법상 목적 달성 시 지체 없는 파기 대상이다.
--
-- ── 왜 아무도 몰랐나 ──────────────────────────────────────────────────────
-- 파기는 안 하면 아무 일도 일어나지 않는다. 기능은 정상 동작하고 화면도 멀쩡하다.
-- 드러나는 경로가 문서와 DB 를 나란히 놓고 대조하는 것뿐이었다(2026-08-03 감사).
--
-- ── 조치 ──────────────────────────────────────────────────────────────────
-- 일일 retention 배치(app.cleanup_retention, cron 03:23)에 한 항목을 더한다.
-- **행을 지우지 않고 전화번호를 NULL 로 만든다.** 이유:
--   · users 를 참조하는 FK 가 30개 넘어서 행 삭제는 부수효과가 크다.
--   · 간이 계정이 가진 개인정보는 전화번호 하나뿐이다. username·nickname 은
--     `lite_<랜덤hex>` 이고 그 밖의 컬럼은 비어 있다 — 번호를 지우면 남는 행은
--     식별력이 없다. withdraw_account 가 정식 회원에 쓰는 익명화와 같은 판단이다.
--   · users_phone_uq 는 `where phone is not null` 부분 인덱스라 NULL 이 여럿이어도
--     충돌하지 않는다(실측 확인).
--
-- 1일 유예를 두는 이유: 간이 토큰 수명이 15분이라 계정 생성과 후기 작성 사이가
-- 그보다 벌어질 일이 없다. 하루면 작성 중인 사람을 지울 위험 없이 충분히 여유롭다.
-- 일 단위 배치의 "지체 없이" 로도 적절하다.
--
-- 파기 후 같은 번호로 다시 오면 새 간이 계정이 만들어진다 — 그게 파기의 의미다.
-- (정식 전환 연결(§5)은 후기가 남아 있는 동안에만 성립하고, 이 파기는 후기가
--  하나도 없을 때만 도는 것이라 §5 와 충돌하지 않는다.)
--
-- ⚠ 운영 현재 정의를 그대로 복사한 뒤 마지막 항목만 덧붙였다 — 공유 함수 재정의로
--   남의 변경을 유실시킨 전례가 있다(20260718190000).
create or replace function app.cleanup_retention()
returns void
language sql
security definer
set search_path = ''
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
$function$;

comment on function app.cleanup_retention() is
  '일일 보존기간 파기 배치(처리방침 §3). 간이 계정은 후기가 0건이면 전화번호를 파기한다.';
