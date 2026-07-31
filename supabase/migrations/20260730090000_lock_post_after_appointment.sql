-- 약속이 완료된 게시글은 수정할 수 없다
--
-- 배경: 지원하기가 붙는 카테고리(산책·대행·돌봄 등 — 자유·입양 제외)는 지원 → 수락 →
-- 약속 → 완료로 이어지고, 완료 시점에 신뢰도·후기가 그 게시글을 근거로 남는다.
-- 그런데 작성자가 그 뒤에도 제목·내용·일정을 바꿀 수 있었다. 성사된 거래의 조건을
-- 사후에 갈아끼울 수 있다는 뜻이라, 후기·신뢰도의 근거가 흔들린다.
--
-- 카테고리로 조건을 걸지 않는다 — '완료된 약속이 있으면' 하나로 충분하다. 자유·입양은
-- 애초에 지원·약속이 생기지 않으므로(0012) 이 조건에 걸릴 일이 없고, 나중에 약속을
-- 쓰는 카테고리가 늘어도 규칙이 자동으로 따라온다.
--
-- 삭제(delete_my_post)는 막지 않는다. 요청 범위가 '수정'이고, 삭제는 작성자가 자기
-- 글을 내리는 별개 권리다(약속·후기는 게시글 소프트 삭제와 무관하게 남는다).
--
-- ⚠️ 클라이언트도 같은 조건으로 저장을 막지만 그건 안내용이다. 이 함수가 정본이다.

begin;

create or replace function public.update_my_post(
  p_post uuid,
  p_title text,
  p_content text,
  p_scheduled_at timestamp with time zone default null::timestamp with time zone,
  p_image_url text default null::text,
  p_image_mime character varying default null::character varying,
  p_image_size integer default null::integer,
  p_edit_image boolean default false,
  p_image_thumb_url text default null::text
)
returns void
language plpgsql
security definer
set search_path to ''
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

  -- 약속이 한 건이라도 완료됐으면 잠근다(위 주석의 근거).
  if exists (
    select 1 from public.appointments a
     where a.post_id = p_post and a.status = 'completed'
  ) then
    raise exception 'appointment_completed' using errcode = 'P0001';
  end if;

  update public.posts set
    title = btrim(p_title),
    content = btrim(p_content),
    scheduled_at = p_scheduled_at,
    edited_at = now(),
    image_url = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_url
      else image_url end,
    image_mime_type = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_mime
      else image_mime_type end,
    image_file_size = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_size
      else image_file_size end,
    image_thumbnail_url = case
      when p_edit_image and v_cat in ('free', 'adoption', 'news') then p_image_thumb_url
      else image_thumbnail_url end
  where id = p_post;

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

-- 작성자에게 '수정 잠김'을 미리 알려주기 위한 조회용(버튼을 숨길지 판단).
-- 완료 여부만 돌려주므로 약속 상세는 드러나지 않는다.
create or replace function public.post_edit_locked(p_post uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.appointments a
     where a.post_id = p_post and a.status = 'completed'
  );
$$;

revoke execute on function public.post_edit_locked(uuid) from public, anon;
grant execute on function public.post_edit_locked(uuid) to authenticated, service_role;

commit;
