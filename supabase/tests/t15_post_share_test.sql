-- 게시글 공유 링크 — 발급·재사용·뷰어 로드·로드 시점 가시성 검증.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(6);

create temp table t15 (k text primary key, id uuid not null);

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);

-- 시드: owner 의 자유 게시글.
with p as (
  insert into public.posts (user_id, category, title, content)
  select id, 'free', '공유 테스트 글', '본문입니다' from seed where k='owner'
  returning id
)
insert into t15 select 'post', id from p;

-- ① 발급 성공(32자 hex).
select lives_ok(
  $$select * from public.create_post_share_link((select id from t15 where k='post'))$$,
  '공유 링크 발급'
);
select is(
  (select count(*)::int from app.share_links
    where kind = 'post' and ref_id = (select id from t15 where k='post')
      and token ~ '^[0-9a-f]{32}$'),
  1,
  '게시글당 링크 1개'
);

-- ② 재호출은 같은 토큰 재사용.
select is(
  (select count(*)::int from app.share_links
    where kind = 'post' and ref_id = (select id from t15 where k='post')
      and token = (select l.token from public.create_post_share_link(
                     (select id from t15 where k='post')) l)),
  1,
  '유효 링크 재사용'
);

-- ③ 뷰어 로드 — 제목·작성자 노출.
select is(
  (select public.share_view_load(
     (select token from app.share_links
       where kind='post' and ref_id=(select id from t15 where k='post')))
   #>> '{post,title}'),
  '공유 테스트 글',
  '뷰어 로드(제목)'
);

-- ④ 로드 시점 가시성 — 삭제되면 not_found.
update public.posts
   set visibility_status = 'deleted_by_user', deleted_at = now()
 where id = (select id from t15 where k='post');
select is(
  (select public.share_view_load(
     (select token from app.share_links
       where kind='post' and ref_id=(select id from t15 where k='post')))
   ->> 'status'),
  'not_found',
  '삭제 게시글 뷰어 차단'
);

-- ⑤ 비가시 게시글엔 신규 발급도 거부.
select throws_like(
  $$select * from public.create_post_share_link((select id from t15 where k='post'))$$,
  '%post_not_found%',
  '삭제 게시글 발급 거부'
);

select * from finish();
rollback;
