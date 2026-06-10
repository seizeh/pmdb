-- 지원 수락 시 나머지 지원자 자동 거절.
--
-- 배경: tg_applications_on_accept 는 수락(pending→accepted) 시 약속 생성 +
--   게시글 progress_status='matched' 잠금만 했고, 같은 게시글의 다른 지원자는
--   'pending' 으로 남아 있었다. 작성자가 1명을 선택하면 나머지는 자동으로
--   거절되도록 보강.
-- 안전성: rejected 전이는 함수 첫 가드(old=pending AND new=accepted)에서 즉시
--   return → 재귀 없음. 알림 트리거(tg_notify_application_accepted)도 accepted
--   에서만 동작하므로 영향 없음.
create or replace function app.tg_applications_on_accept()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_post      public.posts%rowtype;
  v_locked_id uuid;
  v_conflict  int;
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

  insert into public.appointments
    (application_id, post_id, post_owner_id, applicant_id, status, scheduled_at)
  values
    (new.id, new.post_id, v_post.user_id, new.applicant_id, 'scheduled', v_post.scheduled_at);

  -- 나머지 대기 지원자 자동 거절
  update public.applications
     set status = 'rejected'
   where post_id = new.post_id
     and id <> new.id
     and status = 'pending';

  return new;
end;
$function$;
