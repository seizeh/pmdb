-- 업체 소식(news) 카테고리 (0025 후속).
-- 업체 모드 계정의 글은 매칭(지원/약속) 대상이 아니므로 카테고리 선택 없이
-- 항상 'news'(소식)로 분류한다. 개인 모드의 news 사용은 금지(업체 전용 분류).
-- 강제는 앱이 아니라 BEFORE INSERT 트리거에서 — 모든 경로(RPC·직접 INSERT) 커버.

alter table public.posts drop constraint posts_category_check;
alter table public.posts add constraint posts_category_check
  check (category::text = any (array[
    'walk_together','walk_proxy','care','adoption','give_away','free','news'
  ]::text[]));

-- 작성 모드 스냅샷 트리거(20260715120000)에 소식 분류 강제 추가.
create or replace function app.posts_set_authored_as()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  select u.active_mode into new.authored_as
    from public.users u where u.id = new.user_id;
  new.authored_as := coalesce(new.authored_as, 'personal');

  -- 업체 모드 글은 카테고리 무관 항상 '소식' — 매칭 카테고리 사용 불가.
  -- 개인 모드 글의 news 는 거부(소식은 업체 전용 분류).
  if new.authored_as = 'business' then
    new.category := 'news';
  elsif new.category = 'news' then
    raise exception 'posts: 소식 카테고리는 업체 계정 전용이에요';
  end if;

  return new;
end;
$function$;
