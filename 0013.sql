-- ============================================================================
-- PawMate · 0013 · 입양(adoption) 자동 이전
-- ----------------------------------------------------------------------------
-- 분양(give_away)과 방향이 반대: 글 작성자=받는 사람(adopter), 지원자=주는 사람(giver).
-- 글에는 펫이 붙지 않으므로 "지원자가 어떤 펫을 넘길지" 를 application 에 명시.
--   · applications.offered_pet_id 추가 (입양만 필수, 그 외 NULL).
--   · 입양 글 지원 시: offered_pet_id 존재 + 신청자가 그 펫의 owner + 펫 active 검증.
--   · 한 번 지원하면 offered_pet_id 는 불변 (수정 차단).
--   · 펫 점유 충돌 검사(0009)와 약속 INSERT 백스톱이 offered_pet_id 까지 보도록 확장.
--   · 입양 완료 시 transfer: 보호자 전원 정리 → 글 작성자(adopter)만 owner 로.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) applications.offered_pet_id
-- ---------------------------------------------------------------------------
alter table public.applications
  add column if not exists offered_pet_id uuid references public.pets(id);
create index if not exists applications_offered_pet_idx
  on public.applications (offered_pet_id) where offered_pet_id is not null;
comment on column public.applications.offered_pet_id is '입양 글 지원 시 지원자가 넘길 반려동물. 비입양 글에선 NULL';

-- ---------------------------------------------------------------------------
-- 2) tg_applications_block_insert : 입양 검증 추가 (0012 의 모든 기존 검사 포함)
-- ---------------------------------------------------------------------------
create or replace function app.tg_applications_block_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner          uuid;
  v_prog           text;
  v_vis            text;
  v_category       text;
  v_offered_status text;
  v_offered_role   text;
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
  if v_category = 'free' then
    raise exception 'applications: 자유 게시글은 지원 대상이 아닙니다';
  end if;

  -- 신청자가 게시글 펫의 보호자면 차단
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

  -- 카테고리별 offered_pet_id 검증
  if v_category = 'adoption' then
    if new.offered_pet_id is null then
      raise exception 'applications: 입양 게시글은 분양할 반려동물(offered_pet_id) 지정이 필수입니다';
    end if;
    select pet_status into v_offered_status from public.pets where id = new.offered_pet_id;
    if v_offered_status is null then
      raise exception 'applications: 존재하지 않는 반려동물입니다';
    end if;
    if v_offered_status <> 'active' then
      raise exception 'applications: 활성 상태가 아닌 반려동물은 입양 글에 제안할 수 없습니다';
    end if;
    select role into v_offered_role
      from public.pet_guardians
     where pet_id = new.offered_pet_id and user_id = new.applicant_id;
    if v_offered_role is null or v_offered_role <> 'owner' then
      raise exception 'applications: 본인이 소유자(owner)인 반려동물만 입양 글에 제안할 수 있습니다';
    end if;
  else
    if new.offered_pet_id is not null then
      raise exception 'applications: 입양이 아닌 게시글에는 offered_pet_id 를 지정할 수 없습니다';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) offered_pet_id 불변 가드 (지원 후 변경 차단)
-- ---------------------------------------------------------------------------
create or replace function app.tg_applications_immutable_offer()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.offered_pet_id is distinct from new.offered_pet_id then
    raise exception 'applications: offered_pet_id 는 지원 후 변경할 수 없습니다';
  end if;
  return new;
end;
$$;
create or replace trigger trg_applications_immutable_offer
  before update on public.applications
  for each row execute function app.tg_applications_immutable_offer();

-- ---------------------------------------------------------------------------
-- 4) tg_applications_on_accept : 펫 점유 사전 검사에 offered_pet_id 포함
--    (수락 흐름은 그대로, conflict 쿼리만 확장)
-- ---------------------------------------------------------------------------
create or replace function app.tg_applications_on_accept()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_post      public.posts%rowtype;
  v_locked_id uuid;
  v_conflict  int;
begin
  if not (old.status = 'pending' and new.status = 'accepted') then
    return new;
  end if;

  select * into v_post from public.posts where id = new.post_id for update;
  if v_post.id is null then
    raise exception 'applications: 게시글이 존재하지 않습니다';
  end if;

  -- 이 application 의 관련 펫 = post_pets ∪ {offered_pet_id} 가 다른 scheduled 약속에 잡혀 있나
  with new_pets as (
    select pp.pet_id from public.post_pets pp where pp.post_id = new.post_id
    union
    select new.offered_pet_id where new.offered_pet_id is not null
  )
  select count(*) into v_conflict
    from public.appointments a2
   where a2.status = 'scheduled'
     and (
       exists (
         select 1 from public.post_pets pp2
          where pp2.post_id = a2.post_id and pp2.pet_id in (select pet_id from new_pets)
       )
       or exists (
         select 1 from public.applications app2
          where app2.id = a2.application_id
            and app2.offered_pet_id is not null
            and app2.offered_pet_id in (select pet_id from new_pets)
       )
     );
  if v_conflict > 0 then
    raise exception '이 반려동물은 이미 다른 약속이 진행 중입니다. 해당 약속을 완료/취소한 뒤 수락해주세요';
  end if;

  update public.posts
     set progress_status = 'matched'
   where id = new.post_id and progress_status = 'recruiting'
  returning id into v_locked_id;
  if v_locked_id is null then
    raise exception '다른 사용자가 먼저 수락하였습니다';
  end if;

  insert into public.appointments
    (application_id, post_id, post_owner_id, applicant_id, status, scheduled_at)
  values
    (new.id, new.post_id, v_post.user_id, new.applicant_id, 'scheduled', v_post.scheduled_at);

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) tg_appointments_pet_busy_check : 백스톱도 offered_pet_id 포함
-- ---------------------------------------------------------------------------
create or replace function app.tg_appointments_pet_busy_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_conflict int;
begin
  if new.status = 'scheduled' then
    with new_pets as (
      select pp.pet_id from public.post_pets pp where pp.post_id = new.post_id
      union
      select app.offered_pet_id from public.applications app
        where app.id = new.application_id and app.offered_pet_id is not null
    )
    select count(*) into v_conflict
      from public.appointments a2
     where a2.status = 'scheduled'
       and a2.id <> new.id
       and (
         exists (
           select 1 from public.post_pets pp2
            where pp2.post_id = a2.post_id and pp2.pet_id in (select pet_id from new_pets)
         )
         or exists (
           select 1 from public.applications app2
            where app2.id = a2.application_id
              and app2.offered_pet_id is not null
              and app2.offered_pet_id in (select pet_id from new_pets)
         )
       );
    if v_conflict > 0 then
      raise exception '이미 다른 약속이 진행 중인 반려동물이 게시글에 포함되어 있습니다';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) tg_appointments_after_update : 입양 완료 자동 이전 추가
--    (분양 give_away 의 0009 시맨틱은 그대로 유지)
-- ---------------------------------------------------------------------------
create or replace function app.tg_appointments_after_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text;
  v_pet      uuid;
begin
  if old.status = 'scheduled' and new.status = 'completed' then
    update public.posts
       set progress_status = 'completed'
     where id = new.post_id and progress_status = 'matched';
    update public.applications
       set status = 'completed'
     where id = new.application_id and status = 'accepted';

    select category into v_category from public.posts where id = new.post_id;

    if v_category = 'give_away' then
      -- 분양: 글에 붙은 펫이 작성자(giver) → 지원자(receiver) 로
      select pet_id into v_pet from public.post_pets where post_id = new.post_id limit 1;
      if v_pet is not null then
        delete from public.pet_guardians where pet_id = v_pet;
        insert into public.pet_guardians (pet_id, user_id, role, invited_by)
        values (v_pet, new.applicant_id, 'owner', new.post_owner_id);
        update public.pets set primary_guardian_id = new.applicant_id where id = v_pet;
      end if;

    elsif v_category = 'adoption' then
      -- 입양: application 의 offered_pet 이 지원자(giver) → 작성자(adopter) 로
      select offered_pet_id into v_pet from public.applications where id = new.application_id;
      if v_pet is not null then
        delete from public.pet_guardians where pet_id = v_pet;
        insert into public.pet_guardians (pet_id, user_id, role, invited_by)
        values (v_pet, new.post_owner_id, 'owner', new.applicant_id);
        update public.pets set primary_guardian_id = new.post_owner_id where id = v_pet;
      end if;
    end if;

  elsif old.status = 'scheduled' and new.status = 'cancelled' then
    update public.posts
       set progress_status = 'recruiting'
     where id = new.post_id and progress_status = 'matched';
    update public.applications
       set status = 'cancelled'
     where id = new.application_id and status = 'accepted';
  end if;

  return new;
end;
$$;
