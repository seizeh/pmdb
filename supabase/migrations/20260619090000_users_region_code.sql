-- 0017 지역 인증 — 활동 지역 행정동코드 컬럼 추가.
--
-- 인증된 활동 지역을 행정동코드(Naver admcode, 10자리)로 보관한다.
-- 게시글 작성 시 users.region_code = posts.region_code 코드 일치 비교로
-- 지역 검증을 끝내기 위한 키. is_location_verified=true 일 때만 채워진다.
alter table public.users
  add column if not exists region_code varchar(20);

comment on column public.users.region_code is
  '인증된 활동 지역의 행정동코드(Naver admcode, 10자리). is_location_verified=true 일 때 채워짐';

-- 게시글 작성 시 users.region_code = posts.region_code 비교를 위한 인덱스
create index if not exists users_region_code_idx
  on public.users (region_code);
