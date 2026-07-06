-- ============================================================================
-- PawMate · 0008 · 반려동물 N:M 공동보호자 구조
-- ----------------------------------------------------------------------------
-- 문제: users:pets 가 1:N → 한 마리를 여러 보호자가 각자 등록하면 pet 행 중복(무결성 붕괴).
-- 해결: pet 은 한 행만 두고 pet_guardians(N:M)로 여러 보호자를 연결. 계정은 독립.
--   · 최초 등록자 = role='owner' (최고권한). 나머지 = role='co_guardian'.
--   · [권한 결정] owner 전용(강): 펫정보 수정·삭제·분양/입양·보호자 초대/제거·소유권 이전.
--                 co_guardian: 펫 조회 + 그 펫으로 글 작성 + 글에 펫 연결.
--   · 연결 방식 = 초대/요청(pet_guardian_invites). 전화번호로 매칭, 승인 시 연결.
--   · 분양(give_away) 완료 시 소유권이 입양자에게 이전 → 재등록(중복) 방지.
-- 곁다리 수정: post_pets 가 "남의 펫"을 글에 붙일 수 있던 권한 구멍을 보호자 검증으로 차단.
--
-- 주의: 헬퍼 app.is_pet_guardian 은 language sql 이라 CREATE 시 본문이 즉시 파싱·검증됨
--       → pet_guardians 테이블이 먼저 존재해야 함. 그래서 섹션 순서는 [테이블 → 헬퍼].
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) pets.user_id → primary_guardian_id  (rename, 재실행 안전)
--    최고권한자(소유자) 빠른 조회용 비정규화 포인터.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='pets' and column_name='user_id'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='pets' and column_name='primary_guardian_id'
  ) then
    execute 'alter table public.pets rename column user_id to primary_guardian_id';
  end if;
end $$;
comment on column public.pets.primary_guardian_id is '현재 소유자(owner) user_id. 소유권 이전 시 이 값 변경. 전체 보호자는 pet_guardians 참조';

-- ---------------------------------------------------------------------------
-- 2) pet_guardians (N:M)
-- ---------------------------------------------------------------------------
create table if not exists public.pet_guardians (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets(id) on delete cascade,
  user_id    uuid not null references public.users(id),
  role       varchar(20) not null default 'co_guardian'
               check (role in ('owner','co_guardian')),
  invited_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  constraint pet_guardians_uq unique (pet_id, user_id)
);
create index if not exists pet_guardians_user_idx on public.pet_guardians (user_id);
-- 펫당 owner 는 1명만
create unique index if not exists pet_guardians_one_owner_uq
  on public.pet_guardians (pet_id) where role = 'owner';

-- 기존 pets 를 owner 보호자로 시드 (재실행 안전 — on conflict do nothing)
insert into public.pet_guardians (pet_id, user_id, role)
select id, primary_guardian_id, 'owner' from public.pets
on conflict (pet_id, user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 3) 헬퍼: 보호자 여부 (RLS 자기참조 재귀 방지용 SECURITY DEFINER)
--    SQL 함수는 본문이 CREATE 시점에 검증되므로 pet_guardians 생성 뒤에 정의해야 함.
-- ---------------------------------------------------------------------------
create or replace function app.is_pet_guardian(p_pet uuid, p_role text default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.pet_guardians g
    where g.pet_id = p_pet
      and g.user_id = app.uid()
      and (p_role is null or g.role = p_role)
  )
$$;
grant execute on function app.is_pet_guardian(uuid, text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) pets INSERT 시 owner 보호자 자동 생성
-- ---------------------------------------------------------------------------
create or replace function app.tg_pets_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.pet_guardians (pet_id, user_id, role)
  values (new.id, new.primary_guardian_id, 'owner')
  on conflict (pet_id, user_id) do nothing;
  return new;
end;
$$;
create or replace trigger trg_pets_after_insert
  after insert on public.pets
  for each row execute function app.tg_pets_after_insert();

-- ---------------------------------------------------------------------------
-- 5) pet_guardian_invites (초대=owner→대상 / 요청=신청자→owner)
-- ---------------------------------------------------------------------------
create table if not exists public.pet_guardian_invites (
  id              uuid primary key default gen_random_uuid(),
  pet_id          uuid not null references public.pets(id) on delete cascade,
  kind            varchar(10) not null check (kind in ('invite','request')),
  inviter_id      uuid not null references public.users(id),   -- 시작자(invite=owner / request=신청자)
  invitee_phone   varchar(20),                                 -- invite 시 대상 전화(미가입 가능)
  invitee_user_id uuid references public.users(id),            -- 매칭된 대상 user
  status          varchar(20) not null default 'pending'
                    check (status in ('pending','accepted','declined','expired')),
  created_at      timestamptz not null default now(),
  responded_at    timestamptz
);
create index if not exists pgi_pet_idx     on public.pet_guardian_invites (pet_id, status);
create index if not exists pgi_phone_idx    on public.pet_guardian_invites (invitee_phone) where status = 'pending';
create index if not exists pgi_invitee_idx  on public.pet_guardian_invites (invitee_user_id) where status = 'pending';
-- 동일 대상 중복 대기 초대/요청 방지
create unique index if not exists pgi_pending_phone_uq
  on public.pet_guardian_invites (pet_id, invitee_phone)
  where status = 'pending' and invitee_phone is not null;
create unique index if not exists pgi_pending_user_uq
  on public.pet_guardian_invites (pet_id, invitee_user_id)
  where status = 'pending' and invitee_user_id is not null;

-- 5-1) 수락 시 co_guardian 추가 (BEFORE UPDATE: responded_at 세팅 겸용)
create or replace function app.tg_pet_guardian_invites_respond()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_guardian uuid;
begin
  if old.status = 'pending' and new.status = 'accepted' then
    if new.kind = 'invite' then
      v_new_guardian := new.invitee_user_id;   -- owner 가 초대 → 대상이 보호자
    else
      v_new_guardian := new.inviter_id;          -- 신청자가 요청 → 신청자가 보호자
    end if;
    if v_new_guardian is null then
      raise exception 'pet_guardian_invites: 수락 대상 사용자가 확정되지 않았습니다(미가입 전화)';
    end if;
    insert into public.pet_guardians (pet_id, user_id, role, invited_by)
    values (new.pet_id, v_new_guardian, 'co_guardian', new.inviter_id)
    on conflict (pet_id, user_id) do nothing;
    new.responded_at := now();
  elsif old.status = 'pending' and new.status in ('declined','expired') then
    new.responded_at := now();
  end if;
  return new;
end;
$$;
create or replace trigger trg_pgi_respond
  before update on public.pet_guardian_invites
  for each row execute function app.tg_pet_guardian_invites_respond();

-- ---------------------------------------------------------------------------
-- 6) 가입(users INSERT) 시 기본 provisioning + 전화 매칭 초대 연결
--    (0004 의 tg_users_after_insert 를 확장 재정의)
-- ---------------------------------------------------------------------------
create or replace function app.tg_users_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room_id uuid;
begin
  -- 알림 설정 기본 행
  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  -- 관리자 문의 채팅방 (admin 계정 제외)
  if new.user_type <> 'admin' then
    insert into public.chat_rooms (room_type, canonical_key)
    values ('admin_inquiry', 'admin_' || new.id::text)
    on conflict (canonical_key) do nothing
    returning id into v_room_id;

    if v_room_id is not null then
      insert into public.chat_room_members (room_id, user_id)
      values (v_room_id, new.id)
      on conflict (room_id, user_id) do nothing;
    end if;
  end if;

  -- 내 전화번호로 와 있던 대기 초대(invite)에 invitee_user_id 연결 → 가입 후 수락 가능
  if new.phone is not null then
    update public.pet_guardian_invites
       set invitee_user_id = new.id
     where invitee_phone = new.phone
       and status = 'pending'
       and invitee_user_id is null;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7) 게시글 작성권한: pets.user_id → pet_guardians 기반 (owner-only 강권한 반영)
--    (0004 의 tg_posts_check_write 재정의)
-- ---------------------------------------------------------------------------
create or replace function app.tg_posts_check_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_type text;
  v_cnt       int;
begin
  select user_type into v_user_type from public.users where id = new.user_id;
  if v_user_type is null then
    raise exception 'posts: 존재하지 않는 작성자';
  end if;

  -- 분양/대리·동반산책/돌봄: pet_owner 만
  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if v_user_type <> 'pet_owner' then
      raise exception 'posts: % 카테고리는 pet_owner 만 작성 가능', new.category;
    end if;
  end if;

  -- 분양(give_away): 강권한 → 본인이 'owner' 인 활성 펫이 있어야 함
  if new.category = 'give_away' then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and g.role = 'owner' and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: 분양은 본인이 소유자(owner)인 활성 반려동물이 있어야 작성 가능';
    end if;

  -- 동반/대리산책·돌봄: 보호자(owner 또는 co_guardian)인 활성 펫이 있으면 가능
  elsif new.category in ('walk_together','walk_proxy','care') then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: % 카테고리는 보호 중인 활성 반려동물이 있어야 작성 가능', new.category;
    end if;
  end if;

  -- 카테고리별 약속 일정 규칙
  if new.category in ('walk_together','walk_proxy','care') and new.scheduled_at is null then
    raise exception 'posts: % 카테고리는 약속 일정(scheduled_at) 필수', new.category;
  end if;
  if new.category in ('give_away','adoption') and new.scheduled_at is not null then
    raise exception 'posts: % 카테고리는 게시 시 약속 일정을 둘 수 없음', new.category;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8) post_pets 검증: 작성자가 펫 보호자인지 + 분양은 owner·1마리
--    (0004 의 tg_post_pets_giveaway_limit 재정의 — 트리거 바인딩 유지)
-- ---------------------------------------------------------------------------
create or replace function app.tg_post_pets_giveaway_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text;
  v_author   uuid;
  v_existing int;
  v_role     text;
begin
  select category, user_id into v_category, v_author
    from public.posts where id = new.post_id;

  -- 작성자가 해당 펫의 보호자인지(누구든 남의 펫을 붙이는 것 차단)
  select g.role into v_role
    from public.pet_guardians g
   where g.pet_id = new.pet_id and g.user_id = v_author;
  if v_role is null then
    raise exception 'post_pets: 본인이 보호 중인 반려동물만 게시글에 연결할 수 있습니다';
  end if;

  -- 분양: owner 만 + 정확히 1마리
  if v_category = 'give_away' then
    if v_role <> 'owner' then
      raise exception 'post_pets: 분양은 소유자(owner)만 해당 반려동물을 연결할 수 있습니다';
    end if;
    select count(*) into v_existing from public.post_pets where post_id = new.post_id;
    if v_existing >= 1 then
      raise exception 'post_pets: 분양 게시글은 반려동물 1마리만 연결 가능';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9) 분양 완료 시 소유권 이전 (0004 의 tg_appointments_after_update 재정의)
--    ※ 0009 에서 "기존 보호자 전원 정리" 로 다시 갱신됩니다.
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

    -- 분양(give_away) 완료 → 펫 소유권을 입양자에게 이전(재등록=중복 방지)
    select category into v_category from public.posts where id = new.post_id;
    if v_category = 'give_away' then
      select pet_id into v_pet from public.post_pets where post_id = new.post_id limit 1;
      if v_pet is not null then
        -- 기존 owner 강등(부분 unique 충돌 방지를 위해 먼저 수행)
        update public.pet_guardians
           set role = 'co_guardian'
         where pet_id = v_pet and role = 'owner' and user_id <> new.applicant_id;
        -- 새 owner 승격(없으면 추가)
        insert into public.pet_guardians (pet_id, user_id, role, invited_by)
        values (v_pet, new.applicant_id, 'owner', new.post_owner_id)
        on conflict (pet_id, user_id) do update set role = 'owner';
        -- 소유자 포인터 갱신
        update public.pets set primary_guardian_id = new.applicant_id where id = v_pet;
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

-- ===========================================================================
-- 10) RLS · GRANT  (신규/변경 테이블)
-- ===========================================================================

-- 10-1) pets 정책 재정의 (guardian 기반)
drop policy if exists pets_select on public.pets;
drop policy if exists pets_insert on public.pets;
drop policy if exists pets_update on public.pets;

create policy pets_select on public.pets
  for select using (
    pet_status <> 'deleted' or app.is_pet_guardian(id) or app.is_admin()
  );
create policy pets_insert on public.pets
  for insert with check (primary_guardian_id = app.uid());      -- 등록자 = 최초 owner
create policy pets_update on public.pets
  for update using (app.is_pet_guardian(id, 'owner') or app.is_admin())
             with check (app.is_pet_guardian(id, 'owner') or app.is_admin());

-- 10-2) pet_guardians
alter table public.pet_guardians enable row level security;
grant select, insert, update, delete on public.pet_guardians to authenticated;
grant all on public.pet_guardians to service_role;

drop policy if exists pet_guardians_select on public.pet_guardians;
drop policy if exists pet_guardians_insert on public.pet_guardians;
drop policy if exists pet_guardians_update on public.pet_guardians;
drop policy if exists pet_guardians_delete on public.pet_guardians;
create policy pet_guardians_select on public.pet_guardians
  for select using (app.is_pet_guardian(pet_id) or app.is_admin());
create policy pet_guardians_insert on public.pet_guardians
  for insert with check (app.is_pet_guardian(pet_id, 'owner') or app.is_admin());
create policy pet_guardians_update on public.pet_guardians
  for update using (app.is_pet_guardian(pet_id, 'owner') or app.is_admin())
             with check (app.is_pet_guardian(pet_id, 'owner') or app.is_admin());
create policy pet_guardians_delete on public.pet_guardians
  for delete using (app.is_pet_guardian(pet_id, 'owner') or app.is_admin());

-- 10-3) pet_guardian_invites
alter table public.pet_guardian_invites enable row level security;
grant select, insert, update, delete on public.pet_guardian_invites to authenticated;
grant all on public.pet_guardian_invites to service_role;

drop policy if exists pgi_select on public.pet_guardian_invites;
drop policy if exists pgi_insert on public.pet_guardian_invites;
drop policy if exists pgi_update on public.pet_guardian_invites;
create policy pgi_select on public.pet_guardian_invites
  for select using (
    inviter_id = app.uid()
    or invitee_user_id = app.uid()
    or app.is_pet_guardian(pet_id, 'owner')
    or app.is_admin()
  );
-- invite: 펫 owner 만 / request: 누구나(본인 명의)
create policy pgi_insert on public.pet_guardian_invites
  for insert with check (
    inviter_id = app.uid()
    and (
      (kind = 'invite'  and app.is_pet_guardian(pet_id, 'owner'))
      or kind = 'request'
    )
  );
-- 응답(수락/거절): invite→대상 / request→펫 owner
create policy pgi_update on public.pet_guardian_invites
  for update using (
    app.is_admin()
    or (kind = 'invite'  and invitee_user_id = app.uid())
    or (kind = 'request' and app.is_pet_guardian(pet_id, 'owner'))
  );
