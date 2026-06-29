-- 게시글 전용 신고 사유 추가 (0021). 운영 적용 완료(형상 기록).
-- 게시글 신고: '카테고리와 무관해요' / '실제 반려동물이 아니에요' / '기타(직접작성)'.
-- 기존 일반 사유(댓글/사용자/채팅)와 함께 허용.
alter table public.reports drop constraint if exists reports_categories_allowed;
alter table public.reports add constraint reports_categories_allowed
  check (categories <@ array[
    '욕설비방','허위정보','사기의심','부적절한내용','약속불이행','기타',
    '카테고리와 무관해요','실제 반려동물이 아니에요','기타(직접작성)'
  ]::text[]);

-- '기타' 또는 '기타(직접작성)' 선택 시 상세설명 필수
alter table public.reports drop constraint if exists reports_extra_required;
alter table public.reports add constraint reports_extra_required
  check (
    not ('기타' = any(categories) or '기타(직접작성)' = any(categories))
    or (extra_description is not null and length(btrim(extra_description)) > 0)
  );
