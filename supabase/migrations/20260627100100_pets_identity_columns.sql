-- pets 신원 인증 컬럼 (0020)
--
-- 영상 신원 인증 완료 플래그 + AI 추정값(참고/교차검증). definer RPC 만 기록한다.
-- 0019 에서 pets 의 table-wide INSERT/UPDATE GRANT 를 회수하고 컬럼 화이트리스트만
-- 재부여했으므로, 아래 신규 컬럼은 화이트리스트에 없어 클라이언트가 쓸 수 없다(의도).

alter table public.pets
  add column if not exists identity_verified    boolean not null default false,
  add column if not exists identity_verified_at timestamptz,
  add column if not exists ai_species           varchar(10),   -- 영상 AI 동물종 'dog'|'cat'
  add column if not exists ai_breed             varchar(50),   -- 영상 AI 추정 품종(자유)
  add column if not exists ai_colors            text[],        -- 영상 AI 추정 주요 털색
  add column if not exists info_match           jsonb;         -- 등록정보 교차검증 스냅샷

comment on column public.pets.identity_verified is
  '신원 영상 인증(기준 프레임 등록) 완료 여부. 게시글 사진 매칭의 전제 (0020).';
comment on column public.pets.info_match is
  '등록정보 대조 결과. 예: {"species_kind":true,"breed":false,"color":false,"warnings":["breed"]}.';
