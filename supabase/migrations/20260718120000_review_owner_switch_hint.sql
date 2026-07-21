-- 후기 상세 딥링크 진입 시 '업체 모드로 전환할까요?' 제안 판정
--
-- 후기 알림을 탭해 들어온 사용자가 그 시설의 인증 업주인데 현재 개인 모드면
-- 의도치 않게 개인 얼굴로 댓글을 달 수 있다. 클라이언트가 전환 확인창을 띄울지
-- 판단하려면 '이 후기 시설이 내 업체(형제 행 포함)인가 + 지금 개인 모드인가'가
-- 필요한데, 형제 판정은 서버만 안다 → reviewId 하나로 판정하는 헬퍼.
--
-- true 조건: app.uid 가 승인 업체 업주 && 후기 시설이 그 업체 매칭 시설의 형제
--            && 현재 active_mode='personal'. (그 외 전부 false — 타인·비업주·이미 업체모드)

create or replace function public.review_owner_switch_hint(p_review uuid)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1
      from public.facility_reviews fr
      join public.business_profiles bp on bp.user_id = app.uid()
      join public.users u on u.id = app.uid()
     where fr.id = p_review
       and bp.status = 'approved'
       and u.active_mode = 'personal'
       and bp.matched_facility_id = any(public.facility_sibling_ids(fr.facility_id))
  );
$$;

revoke all on function public.review_owner_switch_hint(uuid) from public;
grant execute on function public.review_owner_switch_hint(uuid) to authenticated, service_role;
