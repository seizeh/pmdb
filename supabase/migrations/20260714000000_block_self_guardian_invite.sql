-- 자기 자신 공동보호자 초대 차단 (DB 백스톱).
-- Edge Function(invite-guardian)은 이미 self_invite 를 거르지만, 함수 배포 전
-- 구버전 앱의 직접 INSERT 경로(RLS pgi_insert 는 자기 초대 조건 없음)로
-- inviter=invitee 인 pending 초대가 실제로 생성된 사례가 있다.
-- BEFORE INSERT resolve 트리거에서 최종 확정된 invitee 가 inviter 본인이면
-- 예외를 던져 모든 경로(PostgREST 직접 INSERT·service_role 포함)를 막는다.

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

  -- 자기 자신 초대/요청 차단 (전화번호 resolve 후 최종 값 기준).
  if new.invitee_user_id = new.inviter_id then
    raise exception 'self_invite';
  end if;

  return new;
end;
$function$;

-- 기존에 생성돼 남아 있는 자기 초대 정리 (pending 만 — 알림 트리거는
-- invitee<>inviter 조건이 있어 자기 초대 알림은 애초에 생성되지 않았다).
delete from public.pet_guardian_invites i
 using public.users u
 where u.id = i.inviter_id
   and i.status = 'pending'
   and (i.invitee_user_id = i.inviter_id or i.invitee_phone = u.phone);
