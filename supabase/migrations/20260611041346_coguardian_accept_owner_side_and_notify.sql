-- 수락 시 생성되는 약속의 보호자 측(post_owner_id)을 "실제 수락한 사람"으로 설정.
-- 작성자 또는 게시글 펫의 공동보호자가 수락하면 그 사람이 약속 당사자가 된다.
-- (admin 등 보호자가 아닌 주체가 수락한 예외는 작성자로 fallback)
-- 공동보호자가 작성자 대신 수락하면 작성자에게 알림(application_accepted_by_co)을 보낸다.
--   → 작성자는 약속 당사자가 아니므로 평가 불가, 알림만 받는다.

create or replace function app.tg_applications_on_accept()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_post       public.posts%rowtype;
  v_locked_id  uuid;
  v_conflict   int;
  v_actor      uuid;
  v_owner_side uuid;
begin
  if not (old.status = 'pending' and new.status = 'accepted') then
    return new;
  end if;

  select * into v_post from public.posts where id = new.post_id for update;
  if v_post.id is null then
    raise exception 'applications: 게시글이 존재하지 않습니다';
  end if;

  -- 이 application 의 관련 펫 = post_pets ∪ {offered_pet_id} 가 다른 scheduled 약속에 잡혀 있나
  with new_pets as (
    select pp.pet_id from public.post_pets pp where pp.post_id = new.post_id
    union
    select new.offered_pet_id where new.offered_pet_id is not null
  )
  select count(*) into v_conflict
    from public.appointments a2
   where a2.status = 'scheduled'
     and (
       exists (
         select 1 from public.post_pets pp2
          where pp2.post_id = a2.post_id and pp2.pet_id in (select pet_id from new_pets)
       )
       or exists (
         select 1 from public.applications app2
          where app2.id = a2.application_id
            and app2.offered_pet_id is not null
            and app2.offered_pet_id in (select pet_id from new_pets)
       )
     );
  if v_conflict > 0 then
    raise exception '이 반려동물은 이미 다른 약속이 진행 중입니다. 해당 약속을 완료/취소한 뒤 수락해주세요';
  end if;

  update public.posts
     set progress_status = 'matched'
   where id = new.post_id and progress_status = 'recruiting'
  returning id into v_locked_id;
  if v_locked_id is null then
    raise exception '다른 사용자가 먼저 수락하였습니다';
  end if;

  -- 약속의 보호자 측 = 실제 수락한 사람.
  v_actor := app.uid();
  if v_actor is not null and (
       v_actor = v_post.user_id
       or exists (
         select 1
           from public.post_pets pp
           join public.pet_guardians g on g.pet_id = pp.pet_id
          where pp.post_id = new.post_id and g.user_id = v_actor
       )
     ) then
    v_owner_side := v_actor;
  else
    v_owner_side := v_post.user_id;
  end if;

  insert into public.appointments
    (application_id, post_id, post_owner_id, applicant_id, status, scheduled_at)
  values
    (new.id, new.post_id, v_owner_side, new.applicant_id, 'scheduled', v_post.scheduled_at);

  -- 나머지 대기 지원자 자동 거절
  update public.applications
     set status = 'rejected'
   where post_id = new.post_id
     and id <> new.id
     and status = 'pending';

  -- 공동보호자가 작성자 대신 수락한 경우, 작성자에게 알림(평가 불가, 알림만)
  if v_owner_side is distinct from v_post.user_id then
    begin
      insert into public.notifications
        (user_id, actor_user_id, notification_type, title, body, resource_type, resource_id)
      values
        (v_post.user_id, v_actor, 'application_accepted_by_co',
         '공동보호자가 지원을 수락했어요',
         '내 게시글의 지원이 공동보호자에 의해 수락되었습니다',
         'post', new.post_id);
    exception when others then null;
    end;
  end if;

  return new;
end;
$function$;
