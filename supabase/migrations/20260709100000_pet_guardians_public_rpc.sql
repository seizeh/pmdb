-- 펫 공개 프로필의 보호자 목록(공동보호자 포함) 조회 RPC.
-- pet_guardians 는 RLS 상 그 펫의 보호자만 SELECT 가능해 타인 프로필에서는 못 읽는다.
-- 공개 프로필에는 "누가 보호 중인지"(닉네임/사진/역할)만 필요하므로,
-- definer 로 그 범위만 노출한다 (username/연락처 등 비공개 컬럼은 반환하지 않음).
create or replace function public.pet_guardians_of(p_pet uuid)
returns table(user_id uuid, nickname text, profile_image_url text, role text)
language sql stable security definer set search_path to '' as $function$
  select g.user_id, u.nickname::text, u.profile_image_url, g.role::text
  from public.pet_guardians g
  join public.users u on u.id = g.user_id
  where g.pet_id = p_pet
    and u.deleted_at is null
    and u.status = 'active'
    and exists (
      select 1 from public.pets p
      where p.id = p_pet and p.pet_status <> 'deleted'
    )
  order by (g.role = 'owner') desc, g.created_at
$function$;

revoke all on function public.pet_guardians_of(uuid) from public, anon;
grant execute on function public.pet_guardians_of(uuid) to authenticated;
