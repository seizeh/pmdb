-- ============================================================================
-- 0028 §2 — 영업자 공통 차단선: 승인 업체 계정의 분양·입양 게시 금지
--
-- 기존 불변식(posts_set_authored_as)은 업체 **모드**의 글만 news 로 강제한다 —
-- 승인 영업자가 **개인 모드로 전환**하면 분양(give_away)·입양(adoption) 글을
-- 쓸 수 있는 빈틈이 남는다. 사업계획서 §2.5(영업자의 상업적 판매 게시 금지)와
-- 동물보호법상 판매 알선 리스크 때문에, 활성 모드·업종 조합 무관 예외 없이 차단.
--
-- 별도 트리거로 추가(공유 함수 posts_set_authored_as 재정의 회피 — 병렬 변경
-- 유실 방지). BEFORE 트리거는 이름 알파벳순 실행: trg_posts_authored_as(업체
-- 모드 → news 강제)가 먼저 돌므로 업체 모드 글은 여기 도달 시 이미 news 다.
-- UPDATE OF category 포함 — 개인 글로 넣고 분양으로 수정하는 우회 봉쇄.
--
-- 미인증 영업자(업체 인증 신청 안 함/미승인)는 구조적으로 못 막는다 —
-- 0028 §0 "신고·모니터링 대상" 운영 정책이 담당.
--
-- 기존 데이터: 적용 시점 위반 2건(모두 '입양 희망' 성격, 1건은 이미 삭제) —
-- 소급 삭제 없이 유지(grandfather), 신규 작성·카테고리 변경만 차단.
-- ============================================================================

create or replace function app.tg_posts_block_trader()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.category in ('adoption', 'give_away') and exists (
    select 1 from public.business_profiles b
    where b.user_id = new.user_id and b.status = 'approved'
  ) then
    raise exception 'posts: 영업자 계정은 분양·입양 글을 작성할 수 없어요';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_posts_block_trader on public.posts;
create trigger trg_posts_block_trader
  before insert or update of category on public.posts
  for each row execute function app.tg_posts_block_trader();
