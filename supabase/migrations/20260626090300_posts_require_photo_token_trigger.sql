-- app.tg_posts_check_write 에 사진 실존 검증 토큰 검사 추가 (0018)
--
-- 기존 본문(0008.md: user_type/카테고리/펫/약속일정 규칙)은 그대로 보존하고,
-- 사진 필수 카테고리(walk_together/walk_proxy/care/give_away)에 한해
--   ① image_url 필수(서버 강제)
--   ② 유효한 미사용 photo_verifications 통과 토큰 필수(클라 우회 차단)
-- 를 추가한다. 토큰은 create_post_verified 가 트랜잭션 로컬 세션변수
-- app.photo_token 으로 넘긴다(§ 20260626090400).
-- free/adoption 은 분기 밖이라 사진 선택·미검증(기존 갤러리 업로드) 유지.

create or replace function app.tg_posts_check_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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

  -- 분양/대리·동반산책/돌봄: pet_owner 만
  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if v_user_type <> 'pet_owner' then
      raise exception 'posts: % 카테고리는 pet_owner 만 작성 가능', new.category;
    end if;
  end if;

  -- 분양(give_away): 강권한 → 본인이 'owner' 인 활성 펫이 있어야 함
  if new.category = 'give_away' then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and g.role = 'owner' and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: 분양은 본인이 소유자(owner)인 활성 반려동물이 있어야 작성 가능';
    end if;

  -- 동반/대리산책·돌봄: 보호자(owner 또는 co_guardian)인 활성 펫이 있으면 가능
  elsif new.category in ('walk_together','walk_proxy','care') then
    select count(*) into v_cnt
      from public.pet_guardians g
      join public.pets p on p.id = g.pet_id
     where g.user_id = new.user_id and p.pet_status = 'active';
    if v_cnt < 1 then
      raise exception 'posts: % 카테고리는 보호 중인 활성 반려동물이 있어야 작성 가능', new.category;
    end if;
  end if;

  -- 카테고리별 약속 일정 규칙
  if new.category in ('walk_together','walk_proxy','care') and new.scheduled_at is null then
    raise exception 'posts: % 카테고리는 약속 일정(scheduled_at) 필수', new.category;
  end if;
  if new.category in ('give_away','adoption') and new.scheduled_at is not null then
    raise exception 'posts: % 카테고리는 게시 시 약속 일정을 둘 수 없음', new.category;
  end if;

  -- [0018] 사진 필수 카테고리: 사진 + 서버 검증 토큰 강제
  if new.category in ('walk_together','walk_proxy','care','give_away') then
    if new.image_url is null then
      raise exception 'posts: % 카테고리는 사진 등록이 필요합니다', new.category;
    end if;
    if v_token is null then
      raise exception 'posts: 사진 실존 검증이 필요합니다';
    end if;
    select * into v_pv from public.photo_verifications
      where id = v_token
        and user_id = new.user_id
        and result = 'pass'
        and ai_pass = true
        and region_matched = true
        and consumed_at is null
        and expires_at > now()
        and image_url = new.image_url;         -- AI가 본 사진 == 게시 사진
    if not found then
      raise exception 'posts: 유효하지 않거나 만료된 사진 검증입니다';
    end if;

    -- 토큰 소진 + 검증 결과 비정규화(클라가 못 쓰는 컬럼을 definer 가 채움)
    update public.photo_verifications set consumed_at = now() where id = v_pv.id;
    new.photo_verification_id := v_pv.id;
    new.ai_pet_species        := v_pv.ai_species;
    new.is_pet_verified       := true;
  end if;

  return new;
end;
$$;
