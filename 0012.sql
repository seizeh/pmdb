-- ============================================================================
-- PawMate · 0012 · 자유(free) 게시글 지원/매칭 차단
-- ----------------------------------------------------------------------------
-- 문제: 도메인 문서 4-1 은 자유 카테고리에 "평가 시스템 N" 으로 명시하나,
--   DB 레벨에선 자유 글에도 지원→수락→약속→평가 흐름이 통과해 모순.
-- 해결: applications BEFORE INSERT 트리거에 'free' 카테고리 차단을 추가.
--   (수락 트리거 등은 손댈 필요 없음 — 자유 글 지원 자체가 막히면 후속 단계는 자연히 도달 불가)
-- ============================================================================

create or replace function app.tg_applications_block_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner    uuid;
  v_prog     text;
  v_vis      text;
  v_category text;
begin
  select user_id, progress_status, visibility_status, category
    into v_owner, v_prog, v_vis, v_category
    from public.posts where id = new.post_id;

  if v_owner is null then
    raise exception 'applications: 존재하지 않는 게시글';
  end if;
  if v_owner = new.applicant_id then
    raise exception 'applications: 본인 게시글에는 지원할 수 없습니다';
  end if;
  if v_vis like 'deleted_%' then
    raise exception 'applications: 삭제된 게시글에는 지원할 수 없습니다';
  end if;
  if v_prog <> 'recruiting' then
    raise exception 'applications: 모집이 마감된 게시글입니다 (progress=%)', v_prog;
  end if;

  -- [신규] 자유 게시글은 매칭 대상이 아님
  if v_category = 'free' then
    raise exception 'applications: 자유 게시글은 지원 대상이 아닙니다';
  end if;

  -- 신청자가 게시글 펫의 보호자(owner/co_guardian)면 차단
  if exists (
    select 1 from public.post_pets pp
      join public.pet_guardians g on g.pet_id = pp.pet_id
     where pp.post_id = new.post_id and g.user_id = new.applicant_id
  ) then
    raise exception 'applications: 본인이 보호 중인 반려동물의 게시글에는 지원할 수 없습니다';
  end if;

  -- 게시글에 비활성 펫이 포함되어 있으면 신규 지원 차단
  if exists (
    select 1 from public.post_pets pp
      join public.pets p on p.id = pp.pet_id
     where pp.post_id = new.post_id and p.pet_status <> 'active'
  ) then
    raise exception 'applications: 비활성 반려동물이 포함된 게시글에는 지원할 수 없습니다';
  end if;

  return new;
end;
$$;
