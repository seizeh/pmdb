-- 시설 주기 적재 RPC (0021 §4) — LOCALDATA 행 배치를 받아 upsert.
--
-- ── 설계에서 달라진 점 ──────────────────────────────────────────────────
--
-- ① 0021 은 app.upsert_facilities 로 적었지만 **public 에 둔다.** PostgREST 가
--    app 스키마를 노출하지 않아 .rpc() 로 부를 수 없다. 권한은 service_role
--    전용 GRANT 로 막는다(설계 §7 의 의도와 동일).
--
-- ② 좌표 변환은 DB 에서 한다. 초기 적재는 QGIS 수작업이었는데, 원본 5174 좌표
--    3,000건을 ST_Transform 한 결과가 저장된 좌표와 **오차 0.00 m** 로 일치함을
--    확인했다. 따라서 QGIS 없이도 기존 핀과 어긋나지 않는다.
--
-- ── 반드시 지킬 호출 규약 ───────────────────────────────────────────────
--
-- **폐업·휴업 행을 걸러서 보내지 말 것.** 초기 적재가 '영업/정상'만 넣어 지금
-- DB 에 폐업 행이 0건이다. 거른 채로 보내면 문 닫은 업소의 기존 행이 영영
-- is_open=true 로 남는다(지도는 facilities_within 의 is_open 으로만 거른다).
-- 전부 보내야 옛 행이 내려간다.
--
-- ── 정책 ────────────────────────────────────────────────────────────────
--
-- · 키는 (source='localdata', ext_id=관리번호). 2026-08-10 에 ext_id 를 관리번호로
--   정착시켰다(legacy_ext_id 에 옛 해시 보존).
-- · 업주가 고친 행(owner_updated_at)은 name·phone 을 덮지 않는다. 주소·업종·
--   영업상태는 인허가 데이터 영역이라 항상 덮는다(20260715130000 주석).
-- · 좌표 없는 **신규** 행은 넣지 않는다 — 지도에 찍을 수 없다(현재 596건이
--   이 사유로 제외돼 있고, 그 정책을 유지한다). 반면 **기존** 행은 좌표가 안 와도
--   상태·이름 갱신은 한다(기존 geom 유지).

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
      -- 영업상태명 원문에서 파생. '폐업'·'휴업'·'취소/말소/만료/정지/중지' 는 false.
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
  -- 신규인데 좌표가 없으면 제외(지도에 찍을 수 없다).
  eligible as (
    select p.* from prepared p
     where p.geom is not null
        or exists (select 1 from public.facilities f
                    where f.source = 'localdata' and f.ext_id = p.ext_id)
  ),
  -- 같은 배치에 같은 ext_id 가 두 번 오면 마지막 것만(ON CONFLICT 는 중복을 못 견딘다).
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
      -- 업주 수정본은 간판명·전화를 보존한다.
      name        = case when f.owner_updated_at is null then coalesce(excluded.name, f.name) else f.name end,
      phone       = case when f.owner_updated_at is null then excluded.phone else f.phone end,
      address     = excluded.address,
      biz_status  = excluded.biz_status,
      is_open     = excluded.is_open,
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

comment on function public.upsert_facilities(jsonb) is
  'LOCALDATA 시설 배치 upsert(service_role 전용). 키=(localdata, 관리번호), 좌표는 5174→4326 변환. 폐업 행도 반드시 함께 보낼 것.';
