-- 게시글 사진 인증 게이트 — '신뢰도 3 이상 면제'에서 '펫별 1·4·10번째 글'로 변경.
--
-- 기존: 연결 펫이 모두 trust_score >= 3(약속 완료+후기 3회) 이면 사진 검증 생략.
--       사용자에겐 "언제까지 인증해야 하나"가 보이지 않았고, 약속 후기를 받아야만
--       면제되어 실제로는 거의 항상 촬영을 요구했다.
--
-- 변경: 인증 요구는 **펫별 게시글 순번**으로 결정한다 — 검증 카테고리
--       (walk_together/walk_proxy/care/give_away)의 1·4·10번째 글에서만 촬영 인증을
--       요구하고(총 3회), 그 외에는 면제. 10번째를 넘기면 이후로는 요구하지 않는다.
--       첫 글에서 실존을, 4·10번째에서 표본 재확인을 하는 구조.
--
-- 순번의 근거는 새 컬럼 pets.verify_post_count(그 펫이 지금까지 올린 검증 카테고리
-- 글 수)다. 게시글을 지워도 줄지 않는다 — 지웠다 다시 쓰는 방식으로 게이트를
-- 피하지 못하게 하려는 의도다.
--
-- trust_score/pet_match_count 는 유지한다(배지·신뢰도 표시). 다만 사진 게이트
-- 판정에는 더 이상 쓰지 않는다.
--
-- 이 정의는 2026-07-28 프로덕션 현재 정의(13파라미터, image_thumb_url 포함) 기준이며,
-- 변경점은 게이트 판정 블록뿐이다.

-- 1) 펫별 검증 카테고리 게시글 누적 수 + 조회 권한(사용자 편집 불가 — 트리거만 기록).
alter table public.pets
  add column if not exists verify_post_count int not null default 0;
comment on column public.pets.verify_post_count is
  '검증 카테고리(walk/care/give_away) 게시글 누적 수 — 사진 인증 요구 순번(1·4·10) 판정용. 게시글 삭제로 줄지 않음';
grant select (verify_post_count) on public.pets to anon, authenticated;

-- 2) 기존 데이터 백필 — 삭제된 글도 포함(누적 이력 기준).
update public.pets p
   set verify_post_count = c.cnt
  from (
    select pp.pet_id, count(*)::int as cnt
      from public.post_pets pp
      join public.posts po on po.id = pp.post_id
     where po.category in ('walk_together','walk_proxy','care','give_away')
     group by pp.pet_id
  ) c
 where c.pet_id = p.id and p.verify_post_count <> c.cnt;

-- 3) 게이트 판정 — 다음 글이 1·4·10번째면 촬영 인증 필요.
--    (인자는 '지금까지 올린 글 수' = 다음 글 순번 - 1)
create or replace function app.needs_photo_gate(p_verify_post_count int)
returns boolean language sql immutable set search_path to ''
as $function$ select coalesce(p_verify_post_count, 0) in (0, 3, 9) $function$;
comment on function app.needs_photo_gate(int) is
  '사진 촬영 인증이 필요한 게시글 순번(1·4·10번째)인지 — 앱 MyPet.needsPhotoGate 와 같은 규칙';
-- 앱은 이 규칙을 Dart 에도 갖는다(작성 화면 안내·진행도). app 스키마는 REST 에
-- 노출되지 않으므로 grant 는 두지 않는다 — definer 함수 내부에서만 쓴다.

-- 4) 게시글 등록 시 펫별 누적 수 가산 — RPC 밖(직접 INSERT) 경로도 새지 않도록 트리거로.
create or replace function app.tg_post_pets_bump_verify_count()
returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  update public.pets
     set verify_post_count = verify_post_count + 1
   where id = new.pet_id
     and exists (
           select 1 from public.posts p
            where p.id = new.post_id
              and p.category in ('walk_together','walk_proxy','care','give_away'));
  return new;
end $function$;

drop trigger if exists trg_post_pets_bump_verify_count on public.post_pets;
create trigger trg_post_pets_bump_verify_count
  after insert on public.post_pets
  for each row execute function app.tg_post_pets_bump_verify_count();

-- 5) create_post_verified — 게이트 판정만 순번 기준으로 교체(나머지는 라이브 정의 그대로).
create or replace function public.create_post_verified(
  p_category character varying, p_title character varying, p_content text,
  p_scheduled_at timestamp with time zone, p_pet_ids uuid[],
  p_image_url text, p_image_mime character varying, p_image_size integer,
  p_photo_token uuid default null,
  p_actual_lat double precision default null,
  p_actual_lng double precision default null,
  p_region_code character varying default null,
  p_image_thumb_url text default null
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid  uuid := app.uid();
  v_post uuid;
  v_pv   public.photo_verifications%rowtype;
  v_exempt boolean := false;
  v_user record;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

  -- 동네 인증 게이트 — 업체 모드(소식 전용)는 사업장 주소 기준이라 생략
  -- (승인 여부·지역 스탬프는 tg_posts_set_region 트리거가 강제).
  select region_code, is_location_verified, last_verified_at, active_mode
    into v_user
    from public.users where id = v_uid;
  if v_user.active_mode is distinct from 'business' then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if p_category in ('walk_together','walk_proxy','care','give_away') then
    -- 연결 펫 중 하나라도 이번이 1·4·10번째 글이면 촬영 인증 필요.
    v_exempt := p_pet_ids is not null
            and array_length(p_pet_ids, 1) >= 1
            and not exists (
                  select 1 from public.pets
                   where id = any(p_pet_ids)
                     and app.needs_photo_gate(verify_post_count));

    if v_exempt then
      perform set_config('app.photo_trusted', 'true', true);
    else
      -- 인증이 필요한 글 → 사진 검증 필수. 촬영 대상은 연결 펫 중 아무나
      -- (한 마리 통과로 충분 — 20260720100000 정책 유지).
      select * into v_pv from public.photo_verifications where id = p_photo_token;
      if not found or v_pv.pet_id is null then
        raise exception 'posts: 사진 검증 정보가 올바르지 않습니다';
      end if;
      if p_pet_ids is null or not (v_pv.pet_id = any(p_pet_ids)) then
        raise exception 'posts: 촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다';
      end if;
    end if;
  end if;

  perform set_config('app.photo_token', coalesce(p_photo_token::text, ''), true);

  insert into public.posts (
    user_id, category, title, content, scheduled_at,
    image_url, image_mime_type, image_file_size, image_thumbnail_url,
    actual_lat, actual_lng, region_code
  ) values (
    v_uid, p_category, p_title, p_content, p_scheduled_at,
    p_image_url, p_image_mime, p_image_size, p_image_thumb_url,
    p_actual_lat, p_actual_lng, p_region_code
  ) returning id into v_post;

  -- post_pets 삽입 → trg_post_pets_bump_verify_count 가 펫별 누적 수를 올린다.
  if p_pet_ids is not null and array_length(p_pet_ids, 1) >= 1 then
    insert into public.post_pets (post_id, pet_id)
      select v_post, unnest(p_pet_ids);
  end if;

  if v_pv.id is not null and v_pv.ai_matched then
    update public.pets set pet_match_count = pet_match_count + 1
     where id = v_pv.pet_id;
  end if;

  return v_post;
end;
$function$;
