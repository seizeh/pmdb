-- posts INSERT 최종 방어선 — 동네 인증 게이트를 트리거로.
--
-- posts_insert RLS 는 user_id = app.uid() 만 확인하고 컬럼 GRANT 로
-- category/title/content 등 직접 INSERT 가 가능하므로, RPC(create_post_verified)의
-- 지역 인증 게이트만으로는 자유·분양 카테고리를 직접 INSERT 로 우회할 수 있다.
-- 기존 지역 자동 태깅 트리거(app.tg_posts_set_region)에 게이트를 합쳐
-- 모든 INSERT 경로(RPC 포함)에서 강제한다.
--
-- 30일은 verify-post-photo REVERIFY_DAYS(30)·위치기반서비스 약관과 동일 유지.
-- 관리자(app.is_admin())는 공지 등 운영 글을 위해 예외.

create or replace function app.tg_posts_set_region()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_user record;
begin
  select region_code, is_location_verified, last_verified_at
    into v_user
    from public.users where id = new.user_id;

  if not app.is_admin() then
    if v_user.region_code is null
       or not coalesce(v_user.is_location_verified, false)
       or v_user.last_verified_at is null
       or v_user.last_verified_at < now() - interval '30 days' then
      raise exception 'posts: 동네 인증 후 게시글을 작성할 수 있어요';
    end if;
  end if;

  if new.region_code is null then
    new.region_code := v_user.region_code;
  end if;
  return new;
end $$;
