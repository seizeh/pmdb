-- 차단이 실제로 연결을 끊게 한다 — 표시만 가리던 것을 접촉 자체 차단으로.
--
-- ── 무엇이 문제였나 ────────────────────────────────────────────────────────
-- `user_blocks` 는 스키마 전체에서 다섯 곳에만 참조된다:
--   v_post_feed · v_comment_feed · v_chat_rooms (표시 뷰 3개)
--   chat_block_blocked_user (채팅 전송 거부)
--   block_user (자기 자신)
--
-- 즉 차단은 **내 화면에서 상대를 가리는 것**까지만 하고 있었다. 상대가 나에게
-- 도달하는 경로는 그대로 열려 있었다:
--
--   1. `pawings`(팔로우)가 남는다 → 내가 글을 올릴 때마다 차단한 상대에게
--      `pawing_new_post` 푸시가 간다. **차단이 추적을 끊지 못한다.**
--   2. 알림 생산자 12개 중 어디에도 차단 검사가 없다 → 차단한 상대가 내 글에
--      하트를 누르거나 댓글을 달면 **그 사람 닉네임이 박힌 푸시가 나에게 온다.**
--      (댓글 본문은 v_comment_feed 가 가리므로 알림만 남는 기묘한 상태였다.)
--   3. 차단으로 방이 목록에서 사라져도 그 방의 안읽음이 카운터에 남는다 →
--      **열 수 없는 방 때문에 벨 배지가 영원히 안 맞는다.**
--
-- ── 왜 아무도 몰랐나 ──────────────────────────────────────────────────────
-- 차단은 개발 중에 거의 실행되지 않고, 실행해도 확인하는 건 "목록에서 사라졌나"
-- 뿐이다. 위 세 가지는 전부 **차단한 뒤 시간이 지나야** 드러난다(상대가 다음
-- 글을 올릴 때, 다음 하트를 누를 때). 그 시점엔 차단과 연결 짓기 어렵다.
--
-- 20260801130000 이 "게시글 피드만 걸렀다 … 채팅이 전혀 안 막혀 있었다"며 범위를
-- 넓힌 이력이 있다. 같은 성격의 미완이 남아 있었던 것이고, 이번엔 표시 계층이
-- 아니라 **접촉 계층**을 채운다.
--
-- ── 층 구성 ───────────────────────────────────────────────────────────────
-- 채팅이 이미 쓰고 있는 구조를 그대로 넓힌다:
--   A. 원천 거부 — 하트·댓글 INSERT 자체를 막는다(chat_block_blocked_user 와 같은 모양)
--   B. 안전망 — 차단 쌍 사이의 알림 행을 아예 만들지 않는다
--
-- B 가 필요한 이유: A 로는 크론이 만드는 `pawing_new_post` 나 후기·지원·초대처럼
-- "직접 접촉이 아닌데 알림은 가는" 경로를 못 막는다. 생산자가 12개나 되므로
-- 하나씩 고치면 다음에 추가되는 13번째가 또 빠진다 — **행이 만들어지는 길목**에
-- 한 번 건다.

-- ── 0) 공통 술어 ──────────────────────────────────────────────────────────
-- 방향 무관. 차단은 한쪽이 걸어도 양쪽 관계가 끊겨야 한다(뷰 3개도 이미 그렇다).
create or replace function app.is_blocked_pair(p_a uuid, p_b uuid)
returns boolean
language sql
stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_blocks b
     where (b.blocker_id = p_a and b.blocked_id = p_b)
        or (b.blocker_id = p_b and b.blocked_id = p_a)
  )
$$;

comment on function app.is_blocked_pair(uuid, uuid) is
  '두 사용자가 (방향 무관) 차단 관계인가. 차단 필터의 단일 정의 — 사본을 만들지 말 것.';

-- ── B) 알림 안전망 ────────────────────────────────────────────────────────
-- BEFORE INSERT 에서 NULL 을 돌려주면 그 행은 만들어지지 않는다. notifications 에
-- 다른 BEFORE INSERT 트리거는 없고, AFTER INSERT 둘(푸시 큐잉·안읽음 카운터)은
-- 행이 없으면 아예 발화하지 않으므로 **푸시도 배지도 함께 멈춘다.**
--
-- 예외를 던지지 않고 조용히 건너뛰는 이유: 이 트리거는 남의 트랜잭션 안에서 돈다.
-- 여기서 raise 하면 알림을 만들려던 원래 작업(하트·댓글·후기 INSERT)이 통째로
-- 실패한다. 알림은 부수 효과이므로 부수 효과가 본 작업을 죽이면 안 된다.
-- 접촉 자체를 막는 건 A 의 몫이고, 이건 그물이다.
create or replace function app.tg_notifications_block_filter()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.actor_user_id is not null
     and new.actor_user_id <> new.user_id
     and app.is_blocked_pair(new.user_id, new.actor_user_id)
  then
    return null; -- 행을 만들지 않는다(= 푸시도 배지도 없다)
  end if;
  return new;
end $$;

comment on function app.tg_notifications_block_filter() is
  '차단 쌍 사이의 알림을 생성 단계에서 제거. 생산자 12개를 하나씩 고치는 대신 길목 한 곳.';

drop trigger if exists trg_notifications_block_filter on public.notifications;
create trigger trg_notifications_block_filter
  before insert on public.notifications
  for each row execute function app.tg_notifications_block_filter();

-- 참고: `application_accepted` 만 actor_user_id 를 채우지 않아 이 그물을 통과한다.
-- 의도적으로 둔다 — 그건 사회적 접촉이 아니라 **내가 낸 지원의 결과 통보**이고,
-- 차단했다고 결과를 안 알려주면 사용자가 상태를 알 방법이 없어진다.

-- ── A) 접촉 원천 거부 ─────────────────────────────────────────────────────
-- 채팅과 같은 판단: 차단한 상대와는 상호작용이 성립하지 않는다. 알림만 막으면
-- 하트 수는 올라가고 댓글 행은 저장되는데 아무도 모르는 상태가 된다 — 데이터가
-- 조용히 쌓이는 쪽이 더 나쁘다.
create or replace function app.tg_post_hearts_block_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_owner uuid;
begin
  select p.user_id into v_owner from public.posts p where p.id = new.post_id;
  if v_owner is not null and app.is_blocked_pair(v_owner, new.user_id) then
    raise exception '차단한 사용자의 게시글에는 반응할 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists trg_post_hearts_block_check on public.post_hearts;
create trigger trg_post_hearts_block_check
  before insert on public.post_hearts
  for each row execute function app.tg_post_hearts_block_check();

create or replace function app.tg_comments_block_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_owner uuid;
begin
  select p.user_id into v_owner from public.posts p where p.id = new.post_id;
  if v_owner is not null and app.is_blocked_pair(v_owner, new.user_id) then
    raise exception '차단한 사용자의 게시글에는 댓글을 쓸 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists trg_comments_block_check on public.comments;
create trigger trg_comments_block_check
  before insert on public.comments
  for each row execute function app.tg_comments_block_check();

-- ── 1·3) 차단 시점의 뒷정리 ───────────────────────────────────────────────
-- 운영 현재 정의를 기준으로 뒷정리 두 가지만 덧붙인다.
create or replace function public.block_user(p_blocked uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_blocked is null or p_blocked = v_uid then
    raise exception 'cannot_block_self' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.users u where u.id = p_blocked) then
    raise exception 'user_not_found' using errcode = 'P0001';
  end if;

  insert into public.user_blocks(blocker_id, blocked_id)
  values (v_uid, p_blocked)
  on conflict (blocker_id, blocked_id) do nothing;

  -- ▼ 팔로우 끊기(양방향). 이게 없으면 차단한 상대가 내 팔로워로 남아, 내가 글을
  --   올릴 때마다 크론이 그 사람에게 pawing_new_post 푸시를 보낸다. 알림 그물(B)이
  --   그걸 막긴 하지만, 관계 자체를 남겨 두면 차단 해제 시 예전 팔로우가 되살아나
  --   "왜 이 사람이 나를 팔로우하고 있지" 가 된다. 차단은 관계를 끊는 행위다.
  delete from public.pawings
   where (follower_id = v_uid and following_id = p_blocked)
      or (follower_id = p_blocked and following_id = v_uid);

  -- ▼ 가려진 채팅방의 안읽음 정리. v_chat_rooms 가 차단 상대의 방을 목록에서
  --   빼는데, 그 방의 안읽음은 users.unread_chat_count 에 남는다. 방이 안 보이니
  --   열어서 읽을 수도 없고, app.reconcile_unread_counts 도 가려진 방까지 순회해
  --   같은 값을 다시 계산하므로 **보정으로도 못 지운다.**
  --
  --   leave_chat_room 이 나갈 때 하는 것과 같은 처리를 한다 — 마지막 메시지까지
  --   읽은 것으로 표시. 카운터 감소는 trg_chat_members_read(BEFORE UPDATE)가
  --   알아서 한다. 양쪽 다 처리하는 이유는 뷰가 **양방향**으로 방을 가리기 때문.
  update public.chat_room_members m
     set last_read_message_id = coalesce(
           (select msg.id from public.chat_messages msg
             where msg.room_id = m.room_id
             order by msg.created_at desc, msg.id desc limit 1),
           m.last_read_message_id)
   where m.user_id in (v_uid, p_blocked)
     and m.room_id in (
       select m1.room_id from public.chat_room_members m1
        join public.chat_room_members m2 on m2.room_id = m1.room_id
       where m1.user_id = v_uid and m2.user_id = p_blocked);

  -- 개발자 통보 — 차단은 '이 사용자가 문제였다'는 신고이기도 하다.
  --
  -- reports 에는 유니크가 **둘** 있다:
  --   reports_one_open_per_target — 미처리 건만(부분 인덱스)
  --   reports_uq                  — (reporter, target, type) 상태 무관 전체
  -- 후자 때문에 '과거에 신고했다가 처리 완료된 상대'는 INSERT 가 터진다. 통보는
  -- 부가 기능인데 본 기능(차단)을 막으면 안 되므로 충돌은 흘려보낸다.
  -- ('기타(직접작성)' 은 extra_description 이 비면 reports_extra_required 에 걸린다)
  insert into public.reports(reporter_id, target_type, target_id, categories, extra_description, status)
  values (
    v_uid, 'user', p_blocked, array['기타(직접작성)']::text[],
    coalesce(nullif(btrim(p_reason), ''), '사용자 차단'),
    'submitted'
  )
  on conflict do nothing;
end;
$$;

comment on function public.block_user(uuid, text) is
  '사용자 차단 — 차단 기록 + 신고 접수 + 팔로우 양방향 해제 + 가려진 채팅방 안읽음 정리.';

-- ── 소급 정리 ─────────────────────────────────────────────────────────────
-- 이 마이그레이션 이전에 걸린 차단은 팔로우가 그대로 남아 있다. 지금 정리하지
-- 않으면 "예전에 차단한 사람" 만 계속 새 글 알림을 받는 상태가 남는다.
delete from public.pawings w
 where exists (
   select 1 from public.user_blocks b
    where (b.blocker_id = w.follower_id  and b.blocked_id = w.following_id)
       or (b.blocker_id = w.following_id and b.blocked_id = w.follower_id));

notify pgrst, 'reload schema';
