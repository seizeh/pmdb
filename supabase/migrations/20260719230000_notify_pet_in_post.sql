-- 게시글에 공동보호 펫 등록 시 다른 보호자에게 알림
--
-- ysh 가 게시글에 구름(공동보호 펫)을 등록해 작성하면, 구름의 다른 보호자
-- (owner·co_guardian, 작성자 제외) 전원에게 즉시 알림 — 내 동의 없이 분양 등에
-- 올라가는 걸 알 수 있게. pawing 여부와 무관(보호 관계 기반). 딥링크는 게시글.
-- 게시글 하드삭제 시 post_pets FK cascade 로 이 알림도 함께 정리(미읽음이면
-- unread 카운터 트리거가 감소 처리).

alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (((notification_type)::text = any (array[
    'chat_message'::text, 'post_application'::text, 'post_comment'::text,
    'pawing_new_post'::text, 'application_accepted'::text,
    'application_accepted_by_co'::text, 'review_received'::text,
    'guardian_invite'::text, 'system_notice'::text, 'location_expired'::text,
    'chat_read_receipt'::text, 'unread_sync'::text, 'security_login'::text,
    'schedule_changed'::text, 'business_approved'::text, 'business_rejected'::text,
    'review_comment'::text, 'post_heart'::text, 'pawing_follow'::text,
    'facility_review_received'::text, 'pet_in_post'::text])));

create or replace function app.tg_notify_pet_in_post()
returns trigger
language plpgsql security definer set search_path to ''
as $$
declare
  v_author uuid;
  v_title  text;
  v_pet    text;
  v_actor  text;
begin
  select p.user_id, p.title into v_author, v_title
    from public.posts p where p.id = new.post_id;
  if v_author is null then return new; end if;

  select pt.name into v_pet from public.pets pt where pt.id = new.pet_id;
  select u.nickname into v_actor from public.users u where u.id = v_author;

  -- 이 펫의 다른 보호자(작성자 제외) 전원에게.
  insert into public.notifications
    (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
  select g.user_id, v_author, 'pet_in_post',
         '🐾 ' || coalesce(v_actor, '누군가') || '님이 '
              || coalesce(v_pet, '반려동물') || '(을)를 게시글에 등록했어요',
         app.notif_trunc(v_title), 'post', new.post_id
    from public.pet_guardians g
   where g.pet_id = new.pet_id
     and g.user_id <> v_author
     and not exists (
       select 1 from public.notifications n
        where n.notification_type = 'pet_in_post'
          and n.user_id = g.user_id and n.resource_id = new.post_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_pet_in_post on public.post_pets;
create trigger trg_notify_pet_in_post
  after insert on public.post_pets
  for each row execute function app.tg_notify_pet_in_post();
