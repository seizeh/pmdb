-- 베이스라인의 수기 복원 조각 — build_baseline.py 가 생성한 baseline.sql 끝에 붙는다.
--
-- 스냅샷에서 기계적으로 역산할 수 없는 것만 여기 둔다. 지금은 한 가지다:
--
--   public_profiles 뷰는 기반 스키마에 있었는데, 20260610120125 가
--   `drop view … cascade` 후 다시 만든다(아이디 비공개화). 그래서
--   ① 그 이전 마이그레이션 5개가 이 뷰를 참조하고
--   ② 스냅샷의 최종 정의는 한참 뒤에 생기는 business_profiles 에 의존한다.
--   최종 정의를 베이스라인에 둘 수도, 빼버릴 수도 없으므로 재생성 이전 형태를
--   복원해 둔다. 어차피 20260610120125 가 통째로 갈아치우므로, 그 앞 마이그레이션이
--   쓰는 컬럼(id·nickname·user_type)만 맞으면 된다.
--
-- 리플레이 결과가 스냅샷과 일치하는지는 CI 의 replay 잡이 검증한다.

CREATE VIEW public.public_profiles AS
 SELECT u.id,
    u.nickname,
    u.user_type,
    u.profile_image_url,
    u.address,
    u.is_location_verified,
    u.created_at
   FROM public.users u;

GRANT SELECT ON TABLE public.public_profiles TO anon;
GRANT SELECT ON TABLE public.public_profiles TO authenticated;
