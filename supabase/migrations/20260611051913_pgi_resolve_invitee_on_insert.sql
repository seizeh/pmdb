-- 초대 발송 시점에 전화번호가 이미 가입된 사용자면 invitee_user_id 를 즉시 연결.
-- (기존엔 가입 시점(tg_users_after_insert)에만 연결돼, 이미 가입한 사용자는 초대를 보지 못했음)
-- 미가입 전화는 그대로 null → 추후 가입 시 tg_users_after_insert 가 연결.

create or replace function app.tg_pgi_resolve_invitee()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if new.invitee_user_id is null and new.invitee_phone is not null then
    select id into new.invitee_user_id
      from public.users
     where phone = new.invitee_phone;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_pgi_resolve_invitee on public.pet_guardian_invites;
create trigger trg_pgi_resolve_invitee
  before insert on public.pet_guardian_invites
  for each row execute function app.tg_pgi_resolve_invitee();
