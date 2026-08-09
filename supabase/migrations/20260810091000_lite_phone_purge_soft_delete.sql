-- 간이 후기 계정 전화번호 파기 조건 정정 — 소프트삭제된 후기를 "남은 후기" 로 세던 문제.
--
-- 「간이 후기 이용조건」 §3 과 개인정보 처리방침은 "후기가 모두 삭제되거나 인증 후
-- 후기를 작성하지 않은 경우" 전화번호를 파기한다고 약속한다. 그런데 조건이
--
--     not exists (select 1 from public.facility_reviews r where r.user_id = u.id)
--
-- 이라 **행의 존재만** 봤다. 후기 삭제는 하드 삭제가 아니라 visibility_status 를
-- 'deleted_by_user' 로 바꾸는 소프트 삭제이므로, 후기를 지운 계정은 행이 남아
-- 조건이 영영 거짓 → 전화번호가 무기한 보존된다. 약속과 어긋난다.
--
-- ⚠️ 현재 실제 피해 행은 0건이다(운영 실측: status='lite' 이면서 phone 이 남은
-- 계정 자체가 없음). 잠재 결함을 닫는 것이지 데이터 사고를 수습하는 게 아니다.
--
-- 판정을 **보수적으로** 둔다: 'deleted_by_user' 가 아닌 후기가 하나라도 있으면
-- 보존한다. visibility_status 에는 CHECK 제약이 없어 앞으로 관리자 숨김 같은 값이
-- 늘 수 있는데, 그런 후기는 복구·분쟁 대응 여지가 있어 연결을 끊으면 안 된다.
-- (`= 'visible'` 로 좁게 쓰면 그 경우까지 파기해 버린다.)
--
-- 나머지 본문은 20260804090000 정의와 동일하다 — 이 함수는 통째로 재정의해야 해서
-- 길지만, 바뀌는 것은 맨 아래 간이계정 블록의 not exists 조건 한 곳뿐이다.

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
  --   ⚠️ 삭제는 소프트 삭제다 — 행의 존재가 아니라 **상태**를 봐야 한다.
  update public.users u
     set phone = null,
         phone_verified = false
   where u.status = 'lite'
     and u.phone is not null
     and u.created_at < now() - interval '1 day'
     and not exists (
       select 1 from public.facility_reviews r
        where r.user_id = u.id
          and r.visibility_status <> 'deleted_by_user');

  -- ▼ 관측 데이터. client_errors 와 같은 30일로 맞춘다(같이 보게 되는 자료라 기간이
  --   다르면 "왜 이때는 알람이 없지" 가 보존 차이인지 실제인지 구분이 안 된다).
  delete from app.ops_alarms       where fired_at < now() - interval '30 days';
  delete from app.rate_limit_trips where minute   < now() - interval '30 days';
$function$;

comment on function app.cleanup_retention() is
  '보존기간 만료 데이터 정리(일 1회 크론). 간이계정 전화번호는 deleted_by_user 가 아닌 후기가 없을 때 파기.';
