-- 시설 폐업·이전 제보 + 수동 판정이 재적재를 이겨내게 하기.
--
-- ── 왜 필요한가 ─────────────────────────────────────────────────────────
--
-- LOCALDATA 는 인허가 신고 기반이라 두 겹으로 늦다: 사장님이 시청에 신고할 때까지,
-- 그리고 LOCALDATA 가 배포본에 반영할 때까지(실측 7주 — 2026-08-10 에 받은 파일의
-- 스냅샷이 2026-06-23). 합치면 2~3개월이 하한이고, 신고를 안 하면 영영 안 잡힌다.
-- 실제로 2026-08-01 에 이전한 매장을 사용자가 직접 방문해서야 알았다.
--
-- 닫힌 가게 앞에 선 사용자가 가장 빠른 탐지기인데 제보할 길이 없었다.
--
-- ── 핵심: 수동 판정이 재적재에 지워지면 안 된다 ─────────────────────────
--
-- 제보를 받아 is_open=false 로 내려도, 다음 재적재는 LOCALDATA 를 믿고 다시
-- true 로 되돌린다(그쪽은 아직 '영업/정상'이니까). 그러면 제보 기능이 조용히
-- 무력해진다. 그래서 facilities.reported_closed_at 을 두고 upsert_facilities 가
-- 그 행의 is_open 을 **올리지 않게** 한다. owner_updated_at 이 간판명·전화를
-- 지키는 것과 같은 방식이다.
--
-- 원천이 따라잡으면(LOCALDATA 가 폐업으로 바뀌면) 표시를 지운다 — 그때부터는
-- 공공데이터가 근거이므로 수동 판정을 유지할 이유가 없다.

alter table public.facilities add column if not exists reported_closed_at timestamptz;

comment on column public.facilities.reported_closed_at is
  '관리자가 제보를 확인해 폐업/이전으로 판정한 시각. 설정돼 있으면 재적재가 is_open 을 올리지 않는다.';

-- ── 신고 대상·사유 확장 ────────────────────────────────────────────────

alter table public.reports drop constraint if exists reports_target_type_check;
alter table public.reports add constraint reports_target_type_check
  check (target_type::text = any (array['post','comment','chat_message','user','facility']::text[]));

alter table public.reports drop constraint if exists reports_categories_allowed;
alter table public.reports add constraint reports_categories_allowed
  check (categories <@ array[
    '욕설비방','허위정보','사기의심','부적절한내용','약속불이행','기타',
    '카테고리와 무관해요','실제 반려동물이 아니에요','기타(직접작성)',
    -- 시설 정보 제보(target_type='facility')
    '폐업했어요','이사갔어요','정보가 달라요'
  ]);

-- ── 재적재가 수동 판정을 존중하도록 ────────────────────────────────────
-- 나머지 본문은 20260810110000 과 같다 — is_open 대입부만 바뀐다.

create or replace function public.upsert_facilities(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_ins int := 0;
  v_upd int := 0;
  v_skip int := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array' using errcode = 'P0001';
  end if;

  with rows as (
    select
      (e->>'category')::public.facility_category as category,
      btrim(e->>'ext_id')                        as ext_id,
      nullif(btrim(coalesce(e->>'name','')), '')     as name,
      nullif(btrim(coalesce(e->>'address','')), '')  as address,
      nullif(regexp_replace(coalesce(e->>'phone',''), '\D', '', 'g'), '') as phone,
      nullif(btrim(coalesce(e->>'biz_status','')), '') as biz_status,
      (coalesce(e->>'biz_status','') ~ '영업|정상')  as is_open,
      nullif(btrim(coalesce(e->>'license_date','')), '')::date as license_date,
      nullif(btrim(coalesce(e->>'x','')), '')::double precision as x,
      nullif(btrim(coalesce(e->>'y','')), '')::double precision as y
    from jsonb_array_elements(p_rows) e
  ),
  prepared as (
    select r.*,
           case when r.x is not null and r.y is not null
                then public.st_transform(
                       public.st_setsrid(public.st_makepoint(r.x, r.y), 5174), 4326)::public.geography
           end as geom
      from rows r
     where r.ext_id is not null and r.ext_id <> '' and r.category is not null
  ),
  eligible as (
    select p.* from prepared p
     where p.geom is not null
        or exists (select 1 from public.facilities f
                    where f.source = 'localdata' and f.ext_id = p.ext_id)
  ),
  deduped as (
    select distinct on (ext_id) * from eligible order by ext_id, is_open desc
  ),
  ins as (
    insert into public.facilities as f
      (category, source, ext_id, name, address, phone, biz_status, is_open, license_date, geom)
    select d.category, 'localdata', d.ext_id, coalesce(d.name,'(미상)'), d.address,
           d.phone, d.biz_status, d.is_open, d.license_date, d.geom
      from deduped d
    on conflict (source, ext_id) do update set
      name        = case when f.owner_updated_at is null then coalesce(excluded.name, f.name) else f.name end,
      phone       = case when f.owner_updated_at is null then excluded.phone else f.phone end,
      address     = excluded.address,
      biz_status  = excluded.biz_status,
      -- 제보로 내려간 행은 원천이 아직 '영업중'이어도 다시 올리지 않는다.
      is_open     = case when f.reported_closed_at is not null and excluded.is_open
                         then false else excluded.is_open end,
      -- 원천이 따라잡으면(폐업 확인) 수동 표시를 지운다 — 근거가 공공데이터로 넘어간다.
      reported_closed_at = case when excluded.is_open then f.reported_closed_at else null end,
      license_date = coalesce(excluded.license_date, f.license_date),
      geom        = coalesce(excluded.geom, f.geom),
      updated_at  = now()
    returning (xmax = 0) as inserted
  )
  select count(*) filter (where inserted),
         count(*) filter (where not inserted),
         (select count(*) from prepared) - (select count(*) from deduped)
    into v_ins, v_upd, v_skip
    from ins;

  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'skipped', v_skip);
end $function$;

revoke all on function public.upsert_facilities(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_facilities(jsonb) to service_role;

-- ── 관리자: 제보 확인 → 폐업 판정(또는 해제) ───────────────────────────

create or replace function public.admin_mark_facility_closed(
  p_facility uuid, p_closed boolean default true)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.facilities
     set reported_closed_at = case when p_closed then now() else null end,
         -- 해제 시에는 원천 상태(biz_status)로 되돌린다 — 임의로 true 를 넣지 않는다.
         is_open = case when p_closed then false
                        else (coalesce(biz_status, '') ~ '영업|정상') end,
         updated_at = now()
   where id = p_facility;
  if not found then
    raise exception 'facility_not_found' using errcode = 'P0001';
  end if;
end $function$;

revoke all on function public.admin_mark_facility_closed(uuid, boolean) from public, anon;
grant execute on function public.admin_mark_facility_closed(uuid, boolean) to authenticated;

comment on function public.admin_mark_facility_closed(uuid, boolean) is
  '관리자 폐업 판정. reported_closed_at 을 세워 재적재가 is_open 을 되올리지 못하게 한다.';

-- ── 관리자 화면이 시설 신고 대상을 볼 수 있게 ─────────────────────────
-- 분기를 하나 더하는 것 외에는 현재 정의와 같다.

CREATE OR REPLACE FUNCTION public.admin_get_report_target(p_report uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_type text; v_target uuid; v_out json;
begin
  if not app.is_admin() then raise exception 'forbidden' using errcode='42501'; end if;
  select target_type, target_id into v_type, v_target from public.reports where id = p_report;
  if v_type is null then raise exception 'report_not_found' using errcode='P0001'; end if;

  if v_type = 'post' then
    select json_build_object('kind','post','exists',true,
      'id',p.id,'title',p.title,'content',p.content,
      'author_nickname',coalesce(u.nickname,'알 수 없음'),
      'visibility_status',p.visibility_status,'image_url',p.image_url,'created_at',p.created_at)
    into v_out
    from public.posts p left join public.users u on u.id=p.user_id where p.id=v_target;
  elsif v_type = 'comment' then
    select json_build_object('kind','comment','exists',true,
      'id',c.id,'content',c.content,'is_deleted',c.is_deleted,
      'author_nickname',coalesce(u.nickname,'알 수 없음'),
      'post_id',c.post_id,'post_title',pp.title,'created_at',c.created_at)
    into v_out
    from public.comments c
      left join public.users u on u.id=c.user_id
      left join public.posts pp on pp.id=c.post_id
    where c.id=v_target;
  elsif v_type = 'user' then
    select json_build_object('kind','user','exists',true,
      'id',u.id,'nickname',u.nickname,'username',u.username,
      'status',u.status,'user_type',u.user_type,'created_at',u.created_at)
    into v_out
    from public.users u where u.id=v_target;
  elsif v_type = 'chat_message' then
    select json_build_object('kind','chat_message','exists',true,
      'id',m.id,'content',m.content,'is_deleted',m.is_deleted,
      'room_id',m.room_id,
      'sender_nickname',coalesce(u.nickname,'알 수 없음'),'created_at',m.created_at)
    into v_out
    from public.chat_messages m left join public.users u on u.id=m.sender_id where m.id=v_target;
  elsif v_type = 'facility' then
    select json_build_object('kind','facility','exists',true,
      'id',f.id,'name',f.name,'address',f.address,'category',f.category,
      'biz_status',f.biz_status,'is_open',f.is_open,
      'reported_closed_at',f.reported_closed_at,
      'review_count',f.review_count,'created_at',f.created_at)
    into v_out
    from public.facilities f where f.id=v_target;
  end if;

  if v_out is null then
    v_out := json_build_object('kind', v_type, 'exists', false);
  end if;
  return v_out;
end;
$function$;
