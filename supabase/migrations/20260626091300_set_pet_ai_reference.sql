-- 펫 AI 인증 기준 사진 설정 RPC (0019)
--
-- Edge Function(verify-post-photo, purpose='reference')이 통과 검증을 기록한 뒤 호출.
-- 전달된 verification 이 정말 그 펫의 통과한 reference 인지 확인하고 pets.ai_ref_* 를 채운다.
-- service_role 전용(SECURITY DEFINER).

create or replace function public.set_pet_ai_reference(
  p_pet uuid, p_verification uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_pv public.photo_verifications%rowtype;
begin
  select * into v_pv from public.photo_verifications
    where id = p_verification
      and pet_id = p_pet
      and purpose = 'reference'
      and result = 'pass';
  if not found then
    raise exception 'pets: 유효한 기준 사진 검증이 아닙니다';
  end if;

  update public.pets
     set ai_ref_image_url      = v_pv.image_url,
         ai_ref_image_path     = v_pv.image_path,
         ai_ref_verification_id = v_pv.id,
         ai_ref_verified_at    = now(),
         updated_at            = now()
   where id = p_pet;
end;
$$;

revoke all on function public.set_pet_ai_reference(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.set_pet_ai_reference(uuid, uuid) to service_role;
