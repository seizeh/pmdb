-- 펫 신뢰도(trust_score) 시스템.
--
-- 카메라 인증 게시글(walk/care/give_away)의 약속이 완료되고 평가(리뷰)가 시작되면,
-- 그 게시글에 등록된 반려동물들의 trust_score 를 +1 (약속당 1회, 경쟁상태 안전).
-- 펫의 trust_score >= 3 이면 이후 그 펫으로 작성하는 게시글은 사진 실존 검증을 생략한다.
-- 신뢰도의 대상은 사용자가 아니라 '펫'(post_pets 로 게시글에 연결된 반려동물).

-- 1) 펫 신뢰도 컬럼 + 조회 권한.
alter table public.pets add column if not exists trust_score int not null default 0;
grant select (trust_score) on public.pets to anon, authenticated;

-- 2) 약속당 신뢰도 1회 부여 가드 컬럼.
alter table public.appointments add column if not exists trust_awarded boolean not null default false;

-- 3) 리뷰 최초 등록(약속 완료 상태) 시 게시글 펫들에 +1.
create or replace function app.tg_reviews_grant_pet_trust()
returns trigger language plpgsql security definer set search_path to ''
as $function$
declare v_post uuid;
begin
  -- 완료된 약속의 '첫 평가'일 때만 부여(조건부 UPDATE 가 원자적 락 역할 → 중복/경쟁 방지).
  update public.appointments
     set trust_awarded = true
   where id = new.appointment_id
     and status = 'completed'
     and trust_awarded = false
  returning post_id into v_post;

  if v_post is not null then
    update public.pets p
       set trust_score = p.trust_score + 1
     where p.id in (select pp.pet_id from public.post_pets pp where pp.post_id = v_post);
  end if;
  return new;
end $function$;

drop trigger if exists trg_reviews_grant_pet_trust on public.reviews;
create trigger trg_reviews_grant_pet_trust
  after insert on public.reviews
  for each row execute function app.tg_reviews_grant_pet_trust();

-- 4) 게시글 작성 트리거: 신뢰 펫(모두 trust>=3)이면 사진/토큰 검증 생략.
--    라이브 정의 보존 + app.photo_trusted 세션변수 우회 분기만 추가.
create or replace function app.tg_posts_check_write()
returns trigger language plpgsql security definer set search_path to ''
as $function$
declare
  v_user_type text;
  v_cnt       int;
  v_token     uuid := nullif(current_setting('app.photo_token', true), '')::uuid;
  v_pv        public.photo_verifications%rowtype;
begin
  select user_type into v_user_type from public.users where id = new.user_id;
  if v_user_type is null then
    raise exception 'posts: 존재하지 않는 작성자';
  end if;

  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if v_user_type <> 'pet_owner' then
      raise exception 'posts: % 카테고리는 pet_owner 만 작성 가능', new.category;
    end if;
  end if;

  if new.category = 'give_away' then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and g.role = 'owner' and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: 분양은 본인이 소유자(owner)인 활성 반려동물이 있어야 작성 가능';
    end if;
  elsif new.category in ('walk_together','walk_proxy','care') then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: % 카테고리는 보호 중인 활성 반려동물이 있어야 작성 가능', new.category;
    end if;
  end if;

  if new.category in ('walk_together','walk_proxy','care') and new.scheduled_at is null then
    raise exception 'posts: % 카테고리는 약속 일정(scheduled_at) 필수', new.category;
  end if;
  if new.category in ('give_away','adoption') and new.scheduled_at is not null then
    raise exception 'posts: % 카테고리는 게시 시 약속 일정을 둘 수 없음', new.category;
  end if;

  if new.category in ('walk_together','walk_proxy','care','give_away') then
    -- [신뢰도] create_post_verified 가 모든 연결 펫의 trust>=3 을 확인하면 세팅.
    if coalesce(current_setting('app.photo_trusted', true), '') = 'true' then
      new.is_pet_verified := true;   -- 신뢰 펫: 사진/토큰 검증 생략
    else
      if new.image_url is null then
        raise exception 'posts: % 카테고리는 사진 등록이 필요합니다', new.category;
      end if;
      if v_token is null then
        raise exception 'posts: 사진 실존 검증이 필요합니다';
      end if;
      select * into v_pv from public.photo_verifications
        where id = v_token
          and user_id = new.user_id
          and purpose = 'post'
          and pet_id is not null
          and result = 'pass'
          and ai_pass = true
          and region_matched = true
          and consumed_at is null
          and expires_at > now()
          and image_url = new.image_url;
      if not found then
        raise exception 'posts: 유효하지 않거나 만료된 사진 검증입니다';
      end if;

      update public.photo_verifications set consumed_at = now() where id = v_pv.id;
      new.photo_verification_id := v_pv.id;
      new.ai_pet_species        := v_pv.ai_species;
      new.is_pet_verified       := v_pv.ai_matched;
    end if;
  end if;

  return new;
end;
$function$;

-- 5) create_post_verified: 연결 펫이 모두 신뢰(>=3)면 검증 생략(app.photo_trusted),
--    아니면 기존 토큰 검증 + '촬영 대상은 미인증(trust<3) 펫' 강제.
create or replace function public.create_post_verified(
  p_category character varying, p_title character varying, p_content text,
  p_scheduled_at timestamp with time zone, p_pet_ids uuid[],
  p_image_url text, p_image_mime character varying, p_image_size integer,
  p_photo_token uuid default null,
  p_actual_lat double precision default null,
  p_actual_lng double precision default null,
  p_region_code character varying default null
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare
  v_uid  uuid := app.uid();
  v_post uuid;
  v_pv   public.photo_verifications%rowtype;
  v_all_trusted boolean := false;
begin
  if v_uid is null then
    raise exception 'posts: 로그인이 필요합니다';
  end if;

  if p_category in ('walk_together','walk_proxy','care','give_away') then
    v_all_trusted := p_pet_ids is not null
                 and array_length(p_pet_ids, 1) >= 1
                 and not exists (
                       select 1 from public.pets
                        where id = any(p_pet_ids) and trust_score < 3);

    if v_all_trusted then
      -- 모든 연결 펫이 신뢰 → 사진 검증 생략(트리거 우회 플래그).
      perform set_config('app.photo_trusted', 'true', true);
    else
      -- 미인증 펫 포함 → 사진 검증 필수. 촬영 대상은 미인증 펫이어야 한다.
      select * into v_pv from public.photo_verifications where id = p_photo_token;
      if not found or v_pv.pet_id is null then
        raise exception 'posts: 사진 검증 정보가 올바르지 않습니다';
      end if;
      if p_pet_ids is null or not (v_pv.pet_id = any(p_pet_ids)) then
        raise exception 'posts: 촬영한 반려동물이 게시글에 연결한 반려동물과 다릅니다';
      end if;
      if (select trust_score from public.pets where id = v_pv.pet_id) >= 3 then
        raise exception 'posts: 인증이 필요한 반려동물을 촬영해주세요';
      end if;
    end if;
  end if;

  perform set_config('app.photo_token', coalesce(p_photo_token::text, ''), true);

  insert into public.posts (
    user_id, category, title, content, scheduled_at,
    image_url, image_mime_type, image_file_size,
    actual_lat, actual_lng, region_code
  ) values (
    v_uid, p_category, p_title, p_content, p_scheduled_at,
    p_image_url, p_image_mime, p_image_size,
    p_actual_lat, p_actual_lng, p_region_code
  ) returning id into v_post;

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
