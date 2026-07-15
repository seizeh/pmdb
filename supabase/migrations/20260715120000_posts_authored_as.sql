-- 게시글 작성 모드 구분 (업체 프로필 분리 — "같은 계정, 분리된 프로필").
-- 업체 모드 프로필에서는 일반 모드로 쓴 글이, 일반 프로필에서는 업체 모드로 쓴 글이
-- 보이지 않아야 한다 → 작성 시점의 users.active_mode 를 행에 스냅샷.
-- 기존 글은 전부 업체 기능 도입 전 작성이라 default 'personal' 이 정확하다.

alter table public.posts add column if not exists authored_as varchar not null default 'personal'
  check (authored_as in ('personal','business'));

-- posts 는 컬럼 단위 SELECT 권한 체계(실좌표 비공개) — 새 컬럼은 명시 GRANT 필요.
grant select (authored_as) on public.posts to authenticated, anon;

-- 작성 시점 모드 스냅샷 (BEFORE INSERT — create_post RPC 경유 포함 전 경로).
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
  return new;
end;
$function$;

drop trigger if exists trg_posts_authored_as on public.posts;
create trigger trg_posts_authored_as
  before insert on public.posts
  for each row execute function app.posts_set_authored_as();
