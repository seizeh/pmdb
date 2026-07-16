-- 자기 업체 후기 금지 (0025/0026 후속)
--
-- 업체 인증으로 시설과 연결된 계정(business_profiles.matched_facility_id)은
-- 그 시설에 후기를 남길 수 없다. '하나의 계정, 두 얼굴' 구조라 업체 모드든
-- 개인 모드든 같은 uid — 모드와 무관하게 uid 기준으로 차단한다.
-- 심사중(pending)도 포함: 연결 확정 전 자기 후기 선작성으로 평점을 만드는
-- 우회를 막는다(반려되면 재신청 전까지는 작성 가능해도 무해).
--
-- 클라이언트는 버튼을 숨기지만 불변식은 서버가 정본(직접 호출 우회 방지).

create or replace function public.add_facility_review(
  p_facility uuid,
  p_rating smallint,
  p_body text,
  p_paths text[] default '{}'::text[],
  p_urls text[] default '{}'::text[]
) returns uuid
language plpgsql security definer set search_path to ''
as $$
declare v_uid uuid := app.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;
  if exists (
    select 1 from public.business_profiles bp
     where bp.user_id = v_uid
       and bp.matched_facility_id = p_facility
       and bp.status in ('pending', 'approved')
  ) then
    raise exception 'own_facility' using errcode = 'P0001';
  end if;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'))
  returning id into v_id;
  return v_id;
end $$;
