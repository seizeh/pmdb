-- 시설 방문 후기 댓글 — 게시글 댓글(comments) 문법 미러링.
--  · 로그인 사용자 누구나 작성, 소프트 삭제, 업체 모드 작성 시 상호 노출(authored_as).
--  · 후기 작성자에게 알림(review_comment) — 본인 댓글 제외.
--  · 조회는 v_facility_review_comment_feed(작성자 표시명 포함) 로.

create table public.facility_review_comments (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references public.facility_reviews(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  content text not null,
  authored_as varchar not null default 'personal'
    check (authored_as in ('personal','business')),
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  constraint frc_content_len check (length(btrim(content)) between 1 and 1000)
);

create index frc_review_idx on public.facility_review_comments (review_id, created_at)
  where is_deleted = false;
create index frc_user_idx on public.facility_review_comments (user_id);

alter table public.facility_review_comments enable row level security;

create policy frc_select on public.facility_review_comments
  for select using (is_deleted = false or app.is_admin());
create policy frc_insert on public.facility_review_comments
  for insert with check (user_id = app.uid());
create policy frc_update on public.facility_review_comments
  for update using (user_id = app.uid() or app.is_admin())
        with check (user_id = app.uid() or app.is_admin());

grant select on public.facility_review_comments to anon;
grant select, insert, update on public.facility_review_comments to authenticated;

-- 작성 모드 스냅샷(업체 모드 → 상호 노출) — 게시글 댓글과 동일 함수 재사용.
create trigger trg_frc_authored_as
  before insert on public.facility_review_comments
  for each row execute function app.comments_set_authored_as();

-- 소프트 삭제 시각 스탬프.
create or replace function app.tg_frc_soft_delete_ts()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.is_deleted and not old.is_deleted then
    new.deleted_at := now();
  end if;
  return new;
end $$;
create trigger trg_frc_soft_delete_ts
  before update on public.facility_review_comments
  for each row execute function app.tg_frc_soft_delete_ts();

-- 알림 타입 review_comment 추가 (CHECK 동시 수정 — 안 하면 트리거가 조용히 삼킴).
alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (notification_type::text = any (array[
    'chat_message','post_application','post_comment','pawing_new_post',
    'application_accepted','application_accepted_by_co','review_received',
    'guardian_invite','system_notice','location_expired','chat_read_receipt',
    'unread_sync','security_login','schedule_changed',
    'business_approved','business_rejected','review_comment'
  ]::text[]));

-- resource_type 허용목록에도 facility_review 추가 (알림 타입과 마찬가지로
-- CHECK 를 같이 안 고치면 알림 트리거가 조용히 삼킨다).
alter table public.notifications drop constraint notifications_resource_type_check;
alter table public.notifications add constraint notifications_resource_type_check
  check (resource_type is null or resource_type::text = any (array[
    'post','comment','chat_room','appointment','facility_review'
  ]::text[]));

-- 후기 작성자 알림 (본인 댓글 제외, 실패는 삼켜 댓글 작성을 막지 않음).
create or replace function app.tg_notify_review_comment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_owner uuid;
begin
  begin
    select user_id into v_owner from public.facility_reviews where id = new.review_id;
    if v_owner is not null and v_owner <> new.user_id then
      insert into public.notifications(user_id, actor_user_id, notification_type,
                                       title, resource_type, resource_id)
      values (v_owner, new.user_id, 'review_comment',
              '내 후기에 새 댓글이 달렸어요', 'facility_review', new.review_id);
    end if;
  exception when others then null;
  end;
  return new;
end $$;
create trigger trg_notify_review_comment
  after insert on public.facility_review_comments
  for each row execute function app.tg_notify_review_comment();

-- 조회용 뷰 — 업체 모드 댓글은 상호로(개인 닉네임 비노출), v_comment_feed 와 동일 문법.
create view public.v_facility_review_comment_feed as
 select c.id,
    c.review_id,
    c.user_id,
    c.content,
    c.created_at,
    (case when c.authored_as = 'business'
          then coalesce(bp.business_name, '업체')
          else pr.nickname::text end)::character varying(50) as author_nickname,
    c.authored_as
   from public.facility_review_comments c
     left join public.public_profiles pr on pr.id = c.user_id
     left join public.business_profiles bp
       on bp.user_id = c.user_id and bp.status = 'approved'
  where c.is_deleted = false;

grant select on public.v_facility_review_comment_feed to anon, authenticated;

-- 푸시 설정 매핑: review_comment 는 기존 '댓글'(post_comment) 토글을 따른다.
create or replace function public._push_pref_allows(p_user uuid, p_type text)
returns boolean language sql stable security definer set search_path to ''
as $function$
  select coalesce((
    select case p_type
      when 'chat_message' then chat_message
      when 'post_application' then post_application
      when 'post_comment' then post_comment
      when 'review_comment' then post_comment
      when 'pawing_new_post' then pawing_new_post
      when 'application_accepted' then application_accepted
      when 'review_received' then review_received
      when 'system_notice' then system_notice
      else true
    end
    from public.notification_preferences where user_id = p_user
  ), true)
$function$;
