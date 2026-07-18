-- 타 사용자 프로필의 반려동물 목록 — 공동보호(co_guardian) 펫 포함
--
-- 기존엔 pets.primary_guardian_id 로만 조회해(pet_guardians 는 타인 SELECT 가
-- RLS 로 막힘) 대표 보호자의 펫만 보였다. 그래서 공동보호자로만 연결된 펫이
-- 그 사용자 프로필에서 누락됐다(구름: seizeh=owner 프로필엔 보이나, ysh=
-- co_guardian 프로필엔 안 보임). 펫 상세의 보호자 목록엔 이미 상호 노출되므로
-- 프로필 펫 목록도 대칭이어야 한다.
--
-- SECURITY DEFINER 로 pet_guardians 를 우회 조회하되, 펫 프로필은 공개 정보라
-- 노출 범위 문제 없음(삭제 펫 제외). role/대표보호자 닉네임/보호자 수도 함께.

create or replace function public.public_user_pets(p_user uuid)
returns table (
  id uuid, name varchar, species varchar, gender varchar, birth_date date,
  bio text, image_url text, identity_verified boolean, pet_match_count int,
  role text, owner_name text, guardian_count int
) language sql stable security definer set search_path to 'public'
as $$
  select p.id, p.name, p.species, p.gender, p.birth_date,
         p.bio, p.image_url, p.identity_verified, p.pet_match_count,
         g.role,
         coalesce(ou.nickname, '') as owner_name,
         (select count(*)::int from public.pet_guardians gg where gg.pet_id = p.id) as guardian_count
    from public.pet_guardians g
    join public.pets p on p.id = g.pet_id and p.pet_status <> 'deleted'
    left join public.users ou on ou.id = p.primary_guardian_id
   where g.user_id = p_user
   order by (g.role = 'owner') desc, p.name;
$$;

revoke all on function public.public_user_pets(uuid) from public;
grant execute on function public.public_user_pets(uuid) to anon, authenticated, service_role;
