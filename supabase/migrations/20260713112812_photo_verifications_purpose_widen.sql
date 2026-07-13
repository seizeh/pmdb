-- purpose varchar(10) → varchar(20): 'pet_identity'(12자) 수용.
-- varchar 확장은 메타데이터 변경만이라 테이블 재작성 없음.
alter table public.photo_verifications alter column purpose type varchar(20);
