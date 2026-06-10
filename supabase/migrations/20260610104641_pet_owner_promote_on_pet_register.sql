-- 펫 등록(소유자) 시 users.user_type 을 'pet_owner' 로 자동 승격.
--
-- 배경: tg_posts_check_write 가 walk_together/walk_proxy/care/give_away 카테고리는
--   users.user_type = 'pet_owner' 인지 검사하는데(위반 시 P0001), user_type 은
--   가입 시점에 고정된다. 'no_pet'(반려동물 미보유)으로 가입한 뒤 펫을 등록해도
--   user_type 이 갱신되지 않아 "pet_owner 만 작성 가능"(P0001) 으로 계속 막혔다.
-- 변경: pets INSERT 시 owner pet_guardian 을 만드는 tg_pets_after_insert 트리거에서
--   소유자의 user_type 을 pet_owner 로 승격하는 UPDATE 추가. (다운그레이드는 없음)
-- 도메인: user_type ∈ {pet_owner, no_pet, business, admin}.

create or replace function app.tg_pets_after_insert()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  insert into public.pet_guardians (pet_id, user_id, role)
  values (new.id, new.primary_guardian_id, 'owner')
  on conflict (pet_id, user_id) do nothing;

  -- 펫을 등록하면 소유자가 되므로 작성 권한을 위해 user_type 승격
  update public.users
     set user_type = 'pet_owner'
   where id = new.primary_guardian_id
     and user_type is distinct from 'pet_owner';

  return new;
end;
$function$;

-- 백필: 이미 활성 펫을 소유 중인데 아직 no_pet 인 기존 사용자 교정
update public.users u
   set user_type = 'pet_owner'
 where user_type is distinct from 'pet_owner'
   and exists (
     select 1
       from public.pet_guardians g
       join public.pets p on p.id = g.pet_id
      where g.user_id = u.id
        and g.role = 'owner'
        and p.pet_status = 'active'
   );
