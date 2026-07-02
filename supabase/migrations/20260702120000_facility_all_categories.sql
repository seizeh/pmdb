-- 같은 업체(이름+주소 동일)가 공공데이터상 카테고리별 여러 행으로 존재(예: 동물병원이면서
-- 위탁·미용). 시설 상세에서 해당 업체의 전체 카테고리를 보여주기 위한 조회 RPC.
-- 주소가 없으면 오매칭 방지 위해 자기 카테고리만 반환.
create or replace function public.facility_all_categories(p_id uuid)
returns text[]
language plpgsql stable security definer set search_path to '' as $function$
declare v_name text; v_addr text; v_cat text;
begin
  select name, address, category::text into v_name, v_addr, v_cat
    from public.facilities where id = p_id;
  if v_name is null then return array[]::text[]; end if;
  if v_addr is null then return array[v_cat]; end if;
  return (
    select array_agg(distinct category::text order by category::text)
      from public.facilities
     where name = v_name and address = v_addr
  );
end $function$;

revoke all on function public.facility_all_categories(uuid) from public;
grant execute on function public.facility_all_categories(uuid) to anon, authenticated;
