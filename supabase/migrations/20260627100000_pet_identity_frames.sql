-- 펫 신원 기준 프레임 (0020)
--
-- 펫 등록 시 무작위 임무 영상에서 추출한 프레임 N장. 게시글 사진의 동일개체 매칭 기준.
-- 영상 자체는 저장하지 않는다(프레임만). 0019 의 단일 ai_ref 사진을 대체.
-- 저장 위치: 0018 의 공개 media 버킷 재사용 (<uid>/pet_identity/<pet_id>/<i>.jpg).

create table public.pet_identity_frames (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets(id) on delete cascade,
  frame_index smallint not null,                 -- 0..N-1 (영상 내 위치 순서)
  image_url   text not null,
  image_path  text not null,
  created_at  timestamptz not null default now(),
  constraint pet_identity_frames_uq unique (pet_id, frame_index)
);
create index pet_identity_frames_pet_idx on public.pet_identity_frames (pet_id);

comment on table public.pet_identity_frames is
  '펫 등록 영상에서 추출한 기준 프레임. 게시글 사진 동일개체 매칭에 사용 (0020).';

-- 서버(service_role/definer)만 기록. 조회는 해당 펫의 보호자/관리자.
alter table public.pet_identity_frames enable row level security;

grant select (id, pet_id, frame_index, image_url, created_at)
  on public.pet_identity_frames to authenticated;

create policy pif_select_guardian on public.pet_identity_frames
  for select using (
    exists (
      select 1 from public.pet_guardians g
      where g.pet_id = pet_identity_frames.pet_id and g.user_id = app.uid()
    )
    or app.is_admin()
  );
