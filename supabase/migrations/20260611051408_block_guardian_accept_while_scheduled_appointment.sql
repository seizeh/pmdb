-- 보호자 초대 수락 시점 가드.
-- 보호자가 되려는 사용자가 "이 펫이 포함된 진행 중(scheduled) 약속의 지원자"라면 수락을 차단한다.
-- (지원자가 그 펫의 보호자가 되면 '지원자=관리자'가 되어 지원/약속 관계가 꼬임)
-- 초대 자체는 pending 으로 남아, 약속을 완료/취소한 뒤 다시 수락할 수 있다.

create or replace function app.tg_pet_guardian_invites_respond()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
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

    -- 진행 중 약속의 지원자가 그 펫의 보호자가 되려는 경우 차단
    if exists (
      select 1
        from public.appointments a
        join public.post_pets pp on pp.post_id = a.post_id
       where a.status = 'scheduled'
         and a.applicant_id = v_new_guardian
         and pp.pet_id = new.pet_id
    ) then
      raise exception '진행 중인 약속을 완료한 뒤에 보호자 초대를 수락할 수 있습니다';
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
$function$;
