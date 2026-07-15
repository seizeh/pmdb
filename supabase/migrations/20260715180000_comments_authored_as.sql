-- 댓글 작성 모드 분리 (0026 §5-1 해소) — 업체 모드로 단 댓글은 상호로 표시.
-- posts.authored_as 와 동일한 축: 작성 시점의 users.active_mode 를 행에 스냅샷,
-- 피드 뷰가 업체 댓글의 작성자를 상호(승인 업체)로 치환한다. 기존 댓글은 전부
-- 업체 기능 도입 전 작성이라 default 'personal' 이 정확하다.

alter table public.comments add column if not exists authored_as varchar not null default 'personal'
  check (authored_as in ('personal','business'));

grant select (authored_as) on public.comments to authenticated, anon;

create or replace function app.comments_set_authored_as()
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

drop trigger if exists trg_comments_authored_as on public.comments;
create trigger trg_comments_authored_as
  before insert on public.comments
  for each row execute function app.comments_set_authored_as();

-- 피드 뷰: 업체 댓글 작성자 = 상호(모드 무관·승인 업체), authored_as 노출(얼굴 라우팅용)
create or replace view public.v_comment_feed as
 select c.id,
    c.post_id,
    c.user_id,
    c.content,
    c.created_at,
    (case when c.authored_as = 'business'
          then coalesce(bp.business_name, '업체')
          else pr.nickname::text end)::character varying(50) as author_nickname,
    c.authored_as
   from comments c
     left join public_profiles pr on pr.id = c.user_id
     left join business_profiles bp on bp.user_id = c.user_id and bp.status = 'approved'
  where c.is_deleted = false;
