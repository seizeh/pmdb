-- photo_verifications 에 펫 개체 대조 정보 추가 (0019)
--
-- pet_id        : 이 검증이 묶인 펫(기준 등록 / 게시 매칭 모두).
-- purpose       : 'reference'(펫 기준 사진 등록) | 'post'(게시글 사진 매칭).
-- ai_match_score: 기준 사진 대비 개체 일치도(0~1). reference 는 null.
-- ai_matched    : match_score >= 임계값 (소프트 — 게시 차단은 안 함, 신뢰도 가산 판단용).

alter table public.photo_verifications
  add column if not exists pet_id         uuid references public.pets(id),
  add column if not exists purpose        varchar(10) not null default 'post'
                                            check (purpose in ('reference','post')),
  add column if not exists ai_match_score numeric(4,3),
  add column if not exists ai_matched     boolean not null default false,
  add column if not exists ai_match_reason varchar(200);
