-- 사진 검증 결과 기록 RPC (0018) — 0017 record_location_verification 와 동형.
--
-- Edge Function(verify-post-photo)이 service_role 로 호출한다. 로그 1행을 쓰고
-- photo_verifications.id 를 반환(통과 시 게시글 INSERT 가 소진할 토큰).
-- public 스키마(.rpc 노출), SECURITY DEFINER, service_role 전용.

create or replace function public.record_photo_verification(
  p_user uuid, p_lat numeric, p_lng numeric, p_accuracy int,
  p_region_code varchar, p_region_matched boolean,
  p_species varchar, p_dog_real numeric, p_cat_real numeric,
  p_dog_fake numeric, p_cat_fake numeric, p_ai_pass boolean, p_ai_reason varchar,
  p_result text, p_fail_reason varchar,
  p_image_url text, p_image_path text, p_ttl_min int default 15
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  insert into public.photo_verifications (
    user_id, shot_lat, shot_lng, shot_accuracy_m, region_code, region_matched,
    ai_species, ai_dog_real, ai_cat_real, ai_dog_fake, ai_cat_fake, ai_pass, ai_reason,
    image_url, image_path, result, fail_reason, expires_at
  ) values (
    p_user, p_lat, p_lng, greatest(coalesce(p_accuracy, 0), 0), p_region_code, p_region_matched,
    p_species, p_dog_real, p_cat_real, p_dog_fake, p_cat_fake, p_ai_pass, p_ai_reason,
    p_image_url, p_image_path, p_result, p_fail_reason,
    now() + make_interval(mins => p_ttl_min)
  ) returning id into v_id;
  return v_id;
end;
$$;

-- 클라이언트(anon/authenticated) 호출 불가. service_role(Edge Function) 전용.
revoke all on function public.record_photo_verification(
  uuid, numeric, numeric, int, varchar, boolean, varchar, numeric, numeric,
  numeric, numeric, boolean, varchar, text, varchar, text, text, int)
  from public, anon, authenticated;
grant execute on function public.record_photo_verification(
  uuid, numeric, numeric, int, varchar, boolean, varchar, numeric, numeric,
  numeric, numeric, boolean, varchar, text, varchar, text, text, int)
  to service_role;
