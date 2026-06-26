-- tg_posts_check_write — 개체 대조 토큰 요구 + is_pet_verified=매칭여부 (0019)
--
-- 0018 본문 보존. 검증 카테고리 토큰 검사에 purpose='post' AND pet_id 필수를 추가하고,
-- is_pet_verified 를 "사진 실존 통과"가 아니라 "개체 일치(ai_matched)"로 의미 변경한다.
-- 사진 실존+지역 통과(=token pass)면 게시는 허용(소프트). 일치 실패는 is_pet_verified=false.

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

  -- [0018/0019] 사진 필수 카테고리: 사진 + 개체 대조 토큰 강제
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
        and purpose = 'post'              -- [0019] 게시용 토큰만
        and pet_id is not null            -- [0019] 펫에 묶인 토큰만
        and result = 'pass'
        and ai_pass = true
        and region_matched = true
        and consumed_at is null
        and expires_at > now()
        and image_url = new.image_url;     -- AI가 본 사진 == 게시 사진
    if not found then
      raise exception 'posts: 유효하지 않거나 만료된 사진 검증입니다';
    end if;

    update public.photo_verifications set consumed_at = now() where id = v_pv.id;
    new.photo_verification_id := v_pv.id;
    new.ai_pet_species        := v_pv.ai_species;
    new.is_pet_verified       := v_pv.ai_matched;   -- [0019] 개체 일치 통과 시에만 true
  end if;

  return new;
end;
$$;
