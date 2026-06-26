-- record_photo_verification 재정의 — 펫 개체 대조 인자 추가 (0019)
--
-- 인자 시그니처가 바뀌므로 기존 함수를 DROP 후 재생성한다. service_role 전용 유지.

drop function if exists public.record_photo_verification(
  uuid, numeric, numeric, int, varchar, boolean, varchar, numeric, numeric,
  numeric, numeric, boolean, varchar, text, varchar, text, text, int);

create or replace function public.record_photo_verification(
  p_user uuid, p_lat numeric, p_lng numeric, p_accuracy int,
  p_region_code varchar, p_region_matched boolean,
  p_species varchar, p_dog_real numeric, p_cat_real numeric,
  p_dog_fake numeric, p_cat_fake numeric, p_ai_pass boolean, p_ai_reason varchar,
  p_result text, p_fail_reason varchar,
  p_image_url text, p_image_path text, p_ttl_min int default 15,
  -- [0019] 펫 개체 대조
  p_pet_id uuid default null, p_purpose text default 'post',
  p_match_score numeric default null, p_matched boolean default false,
  p_match_reason varchar default null
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
    image_url, image_path, result, fail_reason, expires_at,
    pet_id, purpose, ai_match_score, ai_matched, ai_match_reason
  ) values (
    p_user, p_lat, p_lng, greatest(coalesce(p_accuracy, 0), 0), p_region_code, p_region_matched,
    p_species, p_dog_real, p_cat_real, p_dog_fake, p_cat_fake, p_ai_pass, p_ai_reason,
    p_image_url, p_image_path, p_result, p_fail_reason,
    now() + make_interval(mins => p_ttl_min),
    p_pet_id, coalesce(p_purpose, 'post'), p_match_score, coalesce(p_matched, false), p_match_reason
  ) returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.record_photo_verification(
  uuid, numeric, numeric, int, varchar, boolean, varchar, numeric, numeric,
  numeric, numeric, boolean, varchar, text, varchar, text, text, int,
  uuid, text, numeric, boolean, varchar)
  from public, anon, authenticated;
grant execute on function public.record_photo_verification(
  uuid, numeric, numeric, int, varchar, boolean, varchar, numeric, numeric,
  numeric, numeric, boolean, varchar, text, varchar, text, text, int,
  uuid, text, numeric, boolean, varchar)
  to service_role;
