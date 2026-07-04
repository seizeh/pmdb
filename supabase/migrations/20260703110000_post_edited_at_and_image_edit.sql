-- 게시글 수정 보강: (A) 수정됨 표기용 edited_at, (B) free/adoption 사진 편집.
-- update_my_post 를 v2 로 교체(edited_at 세팅 + free/adoption 한정 image 갱신).

-- (A) 수정 시각 컬럼. 내용 편집(update_my_post)에서만 세팅 → '수정됨' 신호.
alter table public.posts add column if not exists edited_at timestamptz;
grant select (edited_at) on public.posts to anon, authenticated;

-- v_post_feed 에 edited_at 노출(기존 정의 보존 + 컬럼 추가).
create or replace view public.v_post_feed as
  select p.id, p.category, p.title, p.content, p.user_id,
         pr.nickname as author_nickname, pr.user_type as author_user_type,
         p.created_at, p.scheduled_at, p.display_address as location,
         p.heart_count, p.comment_count, p.view_count, p.progress_status,
         (exists (select 1 from public.post_hearts h
                   where h.post_id = p.id and h.user_id = app.uid())) as hearted,
         p.image_url, p.region_code, pr.address as author_address,
         p.edited_at
    from public.posts p
    left join public.public_profiles pr on pr.id = p.user_id
   where p.visibility_status::text = 'visible'::text
      or p.visibility_status::text = 'hidden_by_user'::text and p.user_id = app.uid()
      or app.is_admin();

-- (B) update_my_post v2: 제목/내용/일정 + edited_at + (free/adoption 만) 사진 갱신.
--     p_edit_image=true 일 때만 이미지 컬럼을 바꾼다(카메라 인증 게시글의 검증 사진 보호).
drop function if exists public.update_my_post(uuid, text, text, timestamptz);
create or replace function public.update_my_post(
  p_post uuid,
  p_title text,
  p_content text,
  p_scheduled_at timestamptz default null,
  p_image_url text default null,
  p_image_mime varchar default null,
  p_image_size int default null,
  p_edit_image boolean default false
) returns void
language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid uuid := app.uid();
  v_owner uuid;
  v_old_sched timestamptz;
  v_cat text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_content), '') = '' then
    raise exception 'posts: 제목과 내용을 입력해주세요';
  end if;

  select user_id, scheduled_at, category into v_owner, v_old_sched, v_cat
  from public.posts where id = p_post for update;
  if v_owner is null then raise exception 'post_not_found'; end if;
  if v_owner <> v_uid then raise exception 'not_owner'; end if;

  update public.posts set
    title = btrim(p_title),
    content = btrim(p_content),
    scheduled_at = p_scheduled_at,
    edited_at = now(),
    image_url = case
      when p_edit_image and v_cat in ('free', 'adoption') then p_image_url
      else image_url end,
    image_mime_type = case
      when p_edit_image and v_cat in ('free', 'adoption') then p_image_mime
      else image_mime_type end,
    image_file_size = case
      when p_edit_image and v_cat in ('free', 'adoption') then p_image_size
      else image_file_size end
  where id = p_post;

  -- 약속 일정이 실제로 바뀌었고 새 일정이 있으면 진행 중 지원자에게 알림.
  if v_old_sched is distinct from p_scheduled_at and p_scheduled_at is not null then
    insert into public.notifications(
      user_id, actor_user_id, notification_type, title, body, resource_type, resource_id
    )
    select a.applicant_id, v_uid, 'schedule_changed', '약속 일정이 변경됐어요',
           btrim(p_title) || ' — '
             || to_char(p_scheduled_at at time zone 'Asia/Seoul', 'MM월 DD일 HH24시') || ' 로 변경',
           'post', p_post
    from public.applications a
    where a.post_id = p_post and a.status in ('pending', 'accepted');
  end if;
end $function$;

grant execute on function public.update_my_post(uuid, text, text, timestamptz, text, varchar, int, boolean)
  to authenticated;
