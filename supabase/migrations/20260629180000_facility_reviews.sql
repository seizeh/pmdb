-- 시설 후기/사진 (0021) — 시설마다 사용자가 별점·후기·사진 작성. 운영 적용 완료(형상 기록).
-- (네이버 플레이스 상세는 공식 API가 없어 앱 자체 후기로 대체)
create table public.facility_reviews (
  id          uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  user_id     uuid not null references public.users(id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  content     text,
  photo_urls  text[] not null default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (facility_id, user_id) -- 시설당 1인 1후기(수정/삭제 가능)
);
create index facility_reviews_facility_idx
  on public.facility_reviews (facility_id, created_at desc);

alter table public.facility_reviews enable row level security;
grant select on public.facility_reviews to authenticated, anon;
grant insert, update, delete on public.facility_reviews to authenticated;

create policy fr_select on public.facility_reviews for select using (true);
create policy fr_insert on public.facility_reviews for insert
  with check (user_id = app.uid());
create policy fr_update on public.facility_reviews for update
  using (user_id = app.uid()) with check (user_id = app.uid());
create policy fr_delete on public.facility_reviews for delete
  using (user_id = app.uid());

-- 작성자 닉네임 + 내 후기 여부 포함 조회 뷰
create view public.v_facility_reviews as
  select r.id, r.facility_id, r.user_id,
         pr.nickname as author_nickname,
         r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine
    from public.facility_reviews r
    left join public.public_profiles pr on pr.id = r.user_id;
grant select on public.v_facility_reviews to authenticated, anon;
