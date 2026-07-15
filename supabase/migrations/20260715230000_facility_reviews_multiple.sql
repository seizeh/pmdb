-- 시설 후기 복수 작성 허용 + 방문 차수(visit_no) 표시.
-- 종전 '1인 1후기(재작성=덮어쓰기)' 정책을 폐지 — 재방문마다 새 후기를 남길 수
-- 있고, 같은 사용자의 후기에는 몇 번째 방문 후기인지 순번을 붙인다.

-- 1) 유니크 해제 → add 는 순수 INSERT 로
alter table public.facility_reviews
  drop constraint if exists facility_reviews_facility_id_user_id_key;

create or replace function public.add_facility_review(
  p_facility uuid, p_rating smallint, p_body text,
  p_paths text[] default '{}'::text[], p_urls text[] default '{}'::text[]
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare v_uid uuid := app.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_rating < 1 or p_rating > 5 then raise exception 'rating 1..5'; end if;
  insert into public.facility_reviews
    (facility_id, user_id, rating, content, photo_paths, photo_urls)
  values (p_facility, v_uid, p_rating, p_body,
          coalesce(p_paths,'{}'), coalesce(p_urls,'{}'))
  returning id into v_id;
  return v_id;
end $function$;

-- 2) 삭제: 특정 후기(id) 지정 지원 — 복수 후기 시대에 '내 후기 전부 삭제'는 위험.
--    p_review 없으면 종전 동작(그 시설의 내 후기 전부 소프트 삭제) 유지(구버전 앱 호환).
drop function if exists public.delete_facility_review(uuid);
create function public.delete_facility_review(
  p_facility uuid,
  p_review uuid default null
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare v_uid uuid := app.uid();
begin
  if v_uid is null then raise exception 'auth required'; end if;
  update public.facility_reviews
     set visibility_status = 'deleted_by_user', updated_at = now()
   where facility_id = p_facility and user_id = v_uid
     and (p_review is null or id = p_review);
end $function$;
revoke all on function public.delete_facility_review(uuid, uuid) from public, anon;
grant execute on function public.delete_facility_review(uuid, uuid) to authenticated;

-- 3) 조회: visit_no(같은 사용자의 몇 번째 후기인지, 시설 내 visible 기준 오름차순)
--    반환 타입 변경 → DROP 재생성 + GRANT 재부여.
drop function if exists public.facility_reviews_of(uuid, integer, integer);
create function public.facility_reviews_of(
  p_facility uuid, p_limit integer default 20, p_offset integer default 0
) returns table (
  id uuid, user_id uuid, author_nickname text, rating smallint, content text,
  photo_urls text[], created_at timestamptz, is_mine boolean, visit_no integer
)
language sql
stable
security definer
set search_path to ''
as $function$
  select r.id, r.user_id, pr.nickname, r.rating, r.content, r.photo_urls, r.created_at,
         (r.user_id = app.uid()) as is_mine, r.visit_no
    from (
      select fr.*,
             row_number() over (
               partition by fr.user_id order by fr.created_at
             )::int as visit_no
        from public.facility_reviews fr
       where fr.facility_id = p_facility and fr.visibility_status = 'visible'
    ) r
    left join public.public_profiles pr on pr.id = r.user_id
   order by r.created_at desc
   limit least(p_limit, 50) offset p_offset;
$function$;
revoke all on function public.facility_reviews_of(uuid, integer, integer) from public;
grant execute on function public.facility_reviews_of(uuid, integer, integer) to authenticated, anon;
