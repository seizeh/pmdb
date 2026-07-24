-- 영상 첨부 불변식 — 게시글 카테고리 게이트·크기 상한, 채팅 미리보기,
-- 시설 후기 videos 검증·조회 노출.
begin;
set local search_path = public, app, extensions;
\ir helpers/seed.sql
select plan(12);

create temp table t14 (k text primary key, id uuid not null);

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from seed where k='owner'), 'tv', 0)::text, true);

-- ① 영상은 자유·소식만 — adoption 에 video mime 직접 INSERT 는 CHECK 거부.
select throws_like(
  $$insert into public.posts (user_id, category, title, content,
      image_url, image_mime_type, image_file_size)
    values ((select id from seed where k='owner'), 'adoption', 't', 'c',
      'v.mp4', 'video/mp4', 1000)$$,
  '%posts_video_category_check%',
  '분양·입양 계열 영상 게시 거부'
);

-- ② 자유 게시글 영상 발행(RPC, 썸네일 포함) 성공 + 썸네일 저장.
with p as (
  select public.create_post_verified(
    'free', '영상글', '본문', null, null,
    'https://x/video.mp4', 'video/mp4', 52428800,
    p_image_thumb_url => 'https://x/thumb.jpg') as id
)
insert into t14 select 'post', id from p;
select is(
  (select image_thumbnail_url from public.posts
    where id = (select id from t14 where k='post')),
  'https://x/thumb.jpg',
  '영상 게시글 발행 + 포스터 저장'
);

-- ③ 영상 100MB 초과는 거부, 사진 12MB 상한은 유지.
select throws_like(
  $$insert into public.posts (user_id, category, title, content,
      image_url, image_mime_type, image_file_size)
    values ((select id from seed where k='owner'), 'free', 't', 'c',
      'v.mp4', 'video/mp4', 104857601)$$,
  '%posts_image_file_size_check%',
  '영상 100MB 초과 거부'
);
select throws_like(
  $$insert into public.posts (user_id, category, title, content,
      image_url, image_mime_type, image_file_size)
    values ((select id from seed where k='owner'), 'free', 't', 'c',
      'p.jpg', 'image/jpeg', 20971520)$$,
  '%posts_image_file_size_check%',
  '사진 12MB 상한 유지'
);

-- ④ 수정 RPC 로 영상 교체(free) — 썸네일 반영.
select lives_ok(
  $$select public.update_my_post(
      (select id from t14 where k='post'), '영상글2', '본문2',
      p_image_url => 'https://x/video2.mp4', p_image_mime => 'video/mp4',
      p_image_size => 1000, p_edit_image => true,
      p_image_thumb_url => 'https://x/thumb2.jpg')$$,
  '영상 게시글 수정'
);
select is(
  (select image_thumbnail_url from public.posts
    where id = (select id from t14 where k='post')),
  'https://x/thumb2.jpg',
  '수정 시 포스터 교체'
);

-- ⑤ 채팅 영상 메시지 — 방 미리보기 [동영상].
with r as (
  insert into public.chat_rooms (room_type, canonical_key)
  values ('direct', 'direct:t14-room') returning id
)
insert into t14 select 'room', id from r;
insert into public.chat_room_members (room_id, user_id)
select (select id from t14 where k='room'), id
  from seed where k in ('owner', 'friend');
insert into public.chat_messages (room_id, sender_id, image_url, image_mime_type, image_file_size)
values ((select id from t14 where k='room'), (select id from seed where k='owner'),
        'https://x/c.mp4', 'video/mp4', 1000);
select is(
  (select last_message_preview from public.chat_rooms
    where id = (select id from t14 where k='room')),
  '[동영상]',
  '채팅 영상 미리보기'
);

-- ⑥ 시설 후기 videos — 검증·저장·조회 노출.
with f as (
  insert into public.facilities (category, source, ext_id, name)
  values ('grooming', 'test', 't14-f1', '영상후기미용실') returning id
)
insert into t14 select 'fac', id from f;

select throws_like(
  $$select public.add_facility_review(
      (select id from t14 where k='fac'), 5::smallint, '후기',
      p_videos => '[{"thumb_url":"t.jpg"}]'::jsonb)$$,
  '%invalid_videos%',
  'url 없는 영상 원소 거부'
);
select throws_like(
  $$select public.add_facility_review(
      (select id from t14 where k='fac'), 5::smallint, '후기',
      p_videos => '[{"url":"a.mp4"},{"url":"b.mp4"},{"url":"c.mp4"}]'::jsonb)$$,
  '%invalid_videos%',
  '영상 2개 초과 거부'
);
select lives_ok(
  $$select public.add_facility_review(
      (select id from t14 where k='fac'), 5::smallint, '영상 후기예요',
      p_videos => '[{"url":"https://x/r.mp4","thumb_url":"https://x/r.jpg"}]'::jsonb)$$,
  '영상 후기 작성'
);
select is(
  (select videos->0->>'url' from public.facility_reviews
    where facility_id = (select id from t14 where k='fac')),
  'https://x/r.mp4',
  '영상 저장'
);
select is(
  (select v.videos->0->>'thumb_url'
     from public.facility_reviews_of((select id from t14 where k='fac')) v
    limit 1),
  'https://x/r.jpg',
  '조회 RPC 에 videos 노출'
);

select * from finish();
rollback;
