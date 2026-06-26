-- 게시글 사진 실존 검증(촬영 위치 일치 + AI 반려동물 판별) 로그 및 1회용 토큰 (0018)
--
-- 0017 의 location_verifications 와 같은 결. Edge Function(verify-post-photo, service_role)이
-- 검증 결과를 1행으로 기록하고 통과 시 id 를 토큰으로 발급한다. 게시글 INSERT 트리거가
-- 그 토큰을 검증·소진하므로 클라이언트는 검증을 우회할 수 없다.
-- 클라이언트 GRANT 는 부여하지 않는다(서버 전용). RLS 만 켜둔다.

create table public.photo_verifications (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id),

  -- 촬영 위치 검증
  shot_lat        decimal(10,7),
  shot_lng        decimal(10,7),
  shot_accuracy_m smallint,
  region_code     varchar(20),                 -- 촬영지 행정동코드(Naver admcode)
  region_matched  boolean not null default false,

  -- AI 판별 결과(클래스별 신뢰도 0~1)
  ai_species      varchar(10),                 -- 'dog' | 'cat' | 'other' | 'none'
  ai_dog_real     numeric(4,3) not null default 0,
  ai_cat_real     numeric(4,3) not null default 0,
  ai_dog_fake     numeric(4,3) not null default 0,
  ai_cat_fake     numeric(4,3) not null default 0,
  ai_pass         boolean not null default false,
  ai_reason       varchar(200),

  -- 검증 토큰(게시글 INSERT 가 소진)
  image_url       text,                        -- 통과 시 서버가 업로드한 공개 URL
  image_path      text,                        -- media 버킷 내 경로(<uid>/posts/…)
  result          varchar(10) not null
                    check (result in ('pass','fail')),
  fail_reason     varchar(40),
  consumed_at     timestamptz,                 -- 게시글에 사용되면 채워짐(재사용 차단)
  expires_at      timestamptz not null,        -- 발급 후 N분 유효
  created_at      timestamptz not null default now()
);

create index photo_verifications_user_idx
  on public.photo_verifications (user_id, created_at desc);

-- 미사용·미만료 통과 토큰 빠른 조회
create index photo_verifications_token_open_idx
  on public.photo_verifications (id)
  where consumed_at is null and result = 'pass';

comment on table public.photo_verifications is
  '게시글 사진 실존 검증(촬영 위치 일치 + AI 반려동물 판별) 로그 및 1회용 토큰 (0018)';

-- 서버(service_role) 전용. authenticated/anon 에 GRANT 미부여 → RLS 정책 없이도 클라 접근 불가.
alter table public.photo_verifications enable row level security;
