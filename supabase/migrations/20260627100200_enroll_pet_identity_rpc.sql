-- 펫 신원 인증 반영 RPC (0020)
--
-- enroll-pet-identity Edge Function 이 service_role 로 호출. 기준 프레임을 교체 insert 하고
-- pets 신원 플래그/AI값을 채운다. public 스키마(.rpc 노출) + SECURITY DEFINER + service_role 전용.
-- (0019 record_photo_verification 와 동일 배치 원칙: .rpc 호출 함수는 public 에.)

create or replace function public.enroll_pet_identity(
  p_pet uuid, p_species varchar, p_paths text[], p_urls text[],
  p_breed varchar default null, p_colors text[] default null,
  p_info_match jsonb default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.pet_identity_frames where pet_id = p_pet;   -- 재등록 시 교체
  insert into public.pet_identity_frames (pet_id, frame_index, image_url, image_path)
    select p_pet, i - 1, p_urls[i], p_paths[i]
      from generate_subscripts(p_urls, 1) as i;
  update public.pets
     set identity_verified = true,
         identity_verified_at = now(),
         ai_species = p_species,
         ai_breed = p_breed,
         ai_colors = p_colors,
         info_match = p_info_match,
         updated_at = now()
   where id = p_pet;
end;
$$;

revoke all on function public.enroll_pet_identity(
  uuid, varchar, text[], text[], varchar, text[], jsonb)
  from public, anon, authenticated;
grant execute on function public.enroll_pet_identity(
  uuid, varchar, text[], text[], varchar, text[], jsonb)
  to service_role;
