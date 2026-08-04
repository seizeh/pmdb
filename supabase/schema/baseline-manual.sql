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


-- pawings_uq — 20260717010000 이 `drop constraint pawings_uq`(IF EXISTS 없음) 로 시작한다.
-- 그 제약은 기반 스키마에 (follower_id, following_id) 2컬럼으로 있었고, 마이그레이션이
-- context 를 넣은 3컬럼으로 바꾼다(두 얼굴 독립 팔로우). context 컬럼 자체도
-- 마이그레이션이 붙이므로 베이스라인에는 2컬럼 형태가 있어야 drop 이 성립한다.
ALTER TABLE ONLY public.pawings
    ADD CONSTRAINT pawings_uq UNIQUE (follower_id, following_id);


-- posts.actual_lat/actual_lng 의 authenticated UPDATE 그랜트 — 20260804140000 이 회수한다.
-- 기반 스키마에 있던 것이라 어느 마이그레이션도 GRANT 하지 않는다. 스냅샷에서 빠진 뒤로는
-- build_baseline.py 가 역산할 근거가 없으므로(회수만 있고 부여가 없다) 여기 수기로 둔다.
-- 이게 없으면 리플레이의 revoke 가 없는 권한을 회수하는 무의미한 no-op 이 되고,
-- "정확 좌표를 못 쓰게 만들었다" 는 사실이 재현 경로에서 사라진다.
GRANT UPDATE(actual_lat) ON TABLE public.posts TO authenticated;
GRANT UPDATE(actual_lng) ON TABLE public.posts TO authenticated;
