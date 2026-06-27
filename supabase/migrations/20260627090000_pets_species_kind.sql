-- 펫 종 분류(강아지/고양이) 컬럼.
--
-- 기존 species(varchar) 는 품종 자유 텍스트("말티즈" 등)로 계속 쓰고,
-- 강아지/고양이 2지선다는 species_kind 로 구조화해 저장한다(0019 dog/cat 판별과 정합).
-- 기존 행은 null 허용(앱에서 신규 등록·수정 시 필수로 강제).

alter table public.pets
  add column if not exists species_kind varchar(10)
    check (species_kind is null or species_kind in ('dog','cat'));

comment on column public.pets.species_kind is
  '종 분류 강아지(dog)/고양이(cat). species 는 품종 자유텍스트.';

-- pets 는 0019 에서 INSERT/UPDATE 컬럼 화이트리스트로 제한됨(table-wide GRANT 회수).
-- → 신규 컬럼을 클라가 쓰도록 화이트리스트에 추가(컬럼 단위 GRANT 는 누적).
grant insert (species_kind) on public.pets to authenticated;
grant update (species_kind) on public.pets to authenticated;
