-- 공동보호자 초대 시 수신자에게 알림(guardian_invite).
-- 1) 알림 타입 허용목록에 guardian_invite 추가
-- 2) 초대 INSERT 시 수신자가 이미 가입자(invitee_user_id 확정)면 알림 생성
-- 3) 미가입 번호로 와 있던 초대가 "가입 시점"에 연결될 때도 알림 생성

alter table public.notifications drop constraint notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check
  check (notification_type::text = any (array[
    'chat_message','post_application','post_comment','pawing_new_post',
    'application_accepted','application_accepted_by_co','review_received',
    'guardian_invite','system_notice','location_expired','chat_read_receipt','unread_sync'
  ]::text[]));

-- 초대 발송(INSERT) 시 알림. invitee_user_id 는 BEFORE INSERT resolve 트리거가 먼저 채운다.
create or replace function app.tg_notify_guardian_invite()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_pet     text;
  v_inviter text;
begin
  begin
    if new.kind = 'invite'
       and new.invitee_user_id is not null
       and new.invitee_user_id <> new.inviter_id then
      select name     into v_pet     from public.pets  where id = new.pet_id;
      select nickname  into v_inviter from public.users where id = new.inviter_id;
      insert into public.notifications(user_id, actor_user_id, notification_type, title, body)
      values (
        new.invitee_user_id, new.inviter_id, 'guardian_invite',
        '공동보호자 초대가 왔어요',
        coalesce(v_inviter,'') || '님이 ' || coalesce(v_pet,'') || '의 공동보호자로 초대했어요'
      );
    end if;
  exception when others then null;
  end;
  return new;
end;
$function$;

drop trigger if exists trg_notify_guardian_invite on public.pet_guardian_invites;
create trigger trg_notify_guardian_invite
  after insert on public.pet_guardian_invites
  for each row execute function app.tg_notify_guardian_invite();

-- 가입 시점에 연결되는 대기 초대에도 알림 (기존 로직 + 알림 블록)
create or replace function app.tg_users_after_insert()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

    -- 방금 연결된 대기 초대들에 대해 알림 생성
    begin
      insert into public.notifications(user_id, actor_user_id, notification_type, title, body)
      select i.invitee_user_id, i.inviter_id, 'guardian_invite',
             '공동보호자 초대가 왔어요',
             coalesce(u.nickname,'') || '님이 ' || coalesce(p.name,'') || '의 공동보호자로 초대했어요'
        from public.pet_guardian_invites i
        join public.pets  p on p.id = i.pet_id
        left join public.users u on u.id = i.inviter_id
       where i.invitee_user_id = new.id
         and i.status = 'pending'
         and i.kind = 'invite'
         and i.invitee_user_id <> i.inviter_id;
    exception when others then null;
    end;
  end if;

  return new;
end;
$function$;
