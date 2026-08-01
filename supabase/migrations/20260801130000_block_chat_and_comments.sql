-- 차단 효력 확대 — 채팅(전송·목록)과 댓글 (App Store 1.2)
--
-- 20260801100000 은 게시글 피드만 걸렀다. 그런데 차단을 테스트하는 가장 자연스러운
-- 자리는 채팅인데 거기가 전혀 안 막혀 있었다 — 차단해도 상대가 계속 메시지를 보내고
-- 내 채팅 목록에 떴다. Apple 문구가 "remove it from the user's feed **instantly**"
-- 이므로 이대로면 1.2 를 다시 지적받는다.
--
-- 셋 다 같은 조건을 쓴다: **양방향** 차단(내가 차단했거나, 나를 차단했거나).
-- 한쪽만 끊으면 상대가 계속 접근할 수 있다.

-- ── 1) 메시지 전송 차단 ─────────────────────────────────────────────────
--
-- 기존 chat_block_left_room(나간 방 INSERT 차단)과 같은 자리다. 그 함수를 고치지
-- 않고 따로 두는 이유는 이름이 곧 사유이고, 에러 메시지도 달라야 하기 때문이다.
-- 클라이언트는 이 메시지를 그대로 사용자에게 보여준다(chat_room_screen).
create or replace function app.chat_block_blocked_user()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if exists (
    select 1
    from public.chat_room_members m
    join public.user_blocks b
      on (b.blocker_id = new.sender_id and b.blocked_id = m.user_id)
      or (b.blocked_id = new.sender_id and b.blocker_id = m.user_id)
    where m.room_id = new.room_id
      and m.user_id <> new.sender_id
  ) then
    raise exception '차단된 상대와는 메시지를 주고받을 수 없어요'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists chat_messages_block_blocked on public.chat_messages;
create trigger chat_messages_block_blocked
  before insert on public.chat_messages
  for each row execute function app.chat_block_blocked_user();

comment on function app.chat_block_blocked_user() is
  '차단 관계(양방향)면 메시지 INSERT 차단 — App Store 1.2.';

-- ── 2) 채팅방 목록에서 숨김 ──────────────────────────────────────────────
create or replace view public.v_chat_rooms as
 SELECT r.id,
    r.last_message_preview,
    r.last_message_at,
    COALESCE(( SELECT
                CASE
                    WHEN (((r.context)::text = 'business'::text) AND (m2.user_id = r.business_user_id)) THEN COALESCE(bp.business_name, (pr.nickname)::text)
                    ELSE (pr.nickname)::text
                END AS nickname
           FROM (((public.chat_room_members m2
             JOIN public.public_profiles pr ON ((pr.id = m2.user_id)))
             JOIN public.users u2 ON ((u2.id = m2.user_id)))
             LEFT JOIN public.business_profiles bp ON (((bp.user_id = m2.user_id) AND ((bp.status)::text = 'approved'::text))))
          WHERE ((m2.room_id = r.id) AND (m2.user_id <> app.uid()) AND (((r.room_type)::text <> 'admin_inquiry'::text) OR ((u2.user_type)::text <> 'admin'::text)))
         LIMIT 1),
        CASE
            WHEN ((r.room_type)::text = 'admin_inquiry'::text) THEN '고객센터'::text
            ELSE '알 수 없음'::text
        END) AS other_nickname,
    ( SELECT m2.user_id
           FROM (public.chat_room_members m2
             JOIN public.users u2 ON ((u2.id = m2.user_id)))
          WHERE ((m2.room_id = r.id) AND (m2.user_id <> app.uid()) AND (((r.room_type)::text <> 'admin_inquiry'::text) OR ((u2.user_type)::text <> 'admin'::text)))
         LIMIT 1) AS other_user_id,
    ( SELECT count(*) AS count
           FROM public.chat_messages cm
          WHERE ((cm.room_id = r.id) AND (cm.is_deleted = false) AND (cm.sender_id <> app.uid()) AND ((m.last_read_message_id IS NULL) OR (cm.created_at > ( SELECT lr.created_at
                   FROM public.chat_messages lr
                  WHERE (lr.id = m.last_read_message_id)))))) AS unread_count,
    (EXISTS ( SELECT 1
           FROM public.chat_room_members m3
          WHERE ((m3.room_id = r.id) AND (m3.user_id <> app.uid()) AND (m3.left_at IS NOT NULL)))) AS other_left,
    ( SELECT
                CASE
                    WHEN (((r.context)::text = 'business'::text) AND (m2.user_id = r.business_user_id)) THEN bp.photo_url
                    ELSE pr.profile_image_url
                END AS profile_image_url
           FROM (((public.chat_room_members m2
             JOIN public.public_profiles pr ON ((pr.id = m2.user_id)))
             JOIN public.users u2 ON ((u2.id = m2.user_id)))
             LEFT JOIN public.business_profiles bp ON (((bp.user_id = m2.user_id) AND ((bp.status)::text = 'approved'::text))))
          WHERE ((m2.room_id = r.id) AND (m2.user_id <> app.uid()) AND (((r.room_type)::text <> 'admin_inquiry'::text) OR ((u2.user_type)::text <> 'admin'::text)))
         LIMIT 1) AS other_profile_image_url,
    r.context
   FROM (public.chat_room_members m
     JOIN public.chat_rooms r ON ((r.id = m.room_id)))
  WHERE ((m.user_id = app.uid()) AND (m.left_at IS NULL))
    -- 차단 관계인 상대와의 방은 목록에서 뺀다. 방을 감추면 그 안의 지난 메시지도
    -- 함께 가려지므로 별도 메시지 필터가 필요 없다.
    AND NOT EXISTS (
      SELECT 1
      FROM public.chat_room_members m4
      JOIN public.user_blocks b
        ON (b.blocker_id = app.uid() AND b.blocked_id = m4.user_id)
        OR (b.blocked_id = app.uid() AND b.blocker_id = m4.user_id)
      WHERE m4.room_id = r.id AND m4.user_id <> app.uid()
    );

-- ── 3) 댓글 ─────────────────────────────────────────────────────────────
--
-- 글은 안 보이는데 그 사람 댓글은 남의 글에 그대로 보이면 차단이 반쪽이다.
create or replace view public.v_comment_feed as
 SELECT c.id,
    c.post_id,
    c.user_id,
    c.content,
    c.created_at,
    (
        CASE
            WHEN ((c.authored_as)::text = 'business'::text) THEN COALESCE(bp.business_name, '업체'::text)
            ELSE (pr.nickname)::text
        END)::character varying(50) AS author_nickname,
    c.authored_as
   FROM ((public.comments c
     LEFT JOIN public.public_profiles pr ON ((pr.id = c.user_id)))
     LEFT JOIN public.business_profiles bp ON (((bp.user_id = c.user_id) AND ((bp.status)::text = 'approved'::text))))
  WHERE (c.is_deleted = false)
    AND (
      app.uid() IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM public.user_blocks b
        WHERE (b.blocker_id = app.uid() AND b.blocked_id = c.user_id)
           OR (b.blocked_id = app.uid() AND b.blocker_id = c.user_id)
      )
    );
