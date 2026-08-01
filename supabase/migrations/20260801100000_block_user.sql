-- 사용자 차단 — 실행 RPC + 피드 필터링 (App Store 1.2 대응)
--
-- 배경: user_blocks 테이블·RLS(INSERT 포함)와 '차단 사용자 관리'(목록·해제) 화면은
-- 이미 있었는데 **차단을 실행하는 경로가 어디에도 없었다**. 읽기·삭제만 하고
-- INSERT 하는 코드가 없어 사실상 죽은 기능이었다.
--
-- Apple 1.2 는 세 가지를 함께 요구한다:
--   (a) 차단 수단
--   (b) 차단 시 개발자에게 통보
--   (c) 해당 콘텐츠가 사용자 피드에서 **즉시** 사라질 것
-- (b)는 reports 에 함께 남겨 관리자 화면(admin_list_reports)에 뜨게 하고,
-- (c)는 v_post_feed 에 필터를 건다.

-- ── (a)+(b) 차단 실행 ────────────────────────────────────────────────────
--
-- SECURITY DEFINER 인 이유: reports 는 신고자 본인만 INSERT 하도록 RLS 가 걸려
-- 있는데, 차단은 '신고까지 한 것'으로 취급해 같은 트랜잭션에서 함께 남겨야 한다.
-- 호출자 검증은 app.uid() 로 직접 한다.
create or replace function public.block_user(
  p_blocked uuid,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path to ''
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

  -- 개발자 통보 — 차단은 '이 사용자가 문제였다'는 신고이기도 하다.
  -- 같은 사람을 차단할 때마다 신고가 쌓이지 않도록 미처리 건이 있으면 건너뛴다.
  if not exists (
    select 1 from public.reports r
    where r.reporter_id = v_uid
      and r.target_type = 'user'
      and r.target_id = p_blocked
      and r.status in ('submitted', 'reviewing')
  ) then
    insert into public.reports(reporter_id, target_type, target_id, categories, extra_description, status)
    values (
      v_uid, 'user', p_blocked, array['기타(직접작성)']::text[],
      -- '기타(직접작성)' 은 extra_description 이 비면 CHECK 에 걸린다(reports_extra_required).
      coalesce(nullif(btrim(p_reason), ''), '사용자 차단'),
      'submitted'
    );
  end if;
end;
$$;

revoke execute on function public.block_user(uuid, text) from anon;
grant execute on function public.block_user(uuid, text) to authenticated;

comment on function public.block_user(uuid, text) is
  '사용자 차단 + 신고 동시 기록(App Store 1.2). 중복 차단·중복 신고는 무해하게 무시.';

-- ── (c) 피드에서 즉시 제외 ───────────────────────────────────────────────
--
-- 내가 차단한 사람의 글과, **나를 차단한 사람의 글**을 모두 뺀다. 후자를 빼는
-- 이유는 차단이 한쪽만 끊으면 상대가 계속 내 글에 접근·반응할 수 있어서다.
-- 관리자(app.is_admin())는 종전대로 전부 본다 — 신고 처리에 필요하다.
create or replace view public.v_post_feed as
 SELECT p.id,
    p.category,
    p.title,
    p.content,
    p.user_id,
    (
        CASE
            WHEN ((p.authored_as)::text = 'business'::text) THEN COALESCE(bp.business_name, '업체'::text)
            ELSE (pr.nickname)::text
        END)::character varying(50) AS author_nickname,
    pr.user_type AS author_user_type,
    p.created_at,
    p.scheduled_at,
    p.display_address AS location,
    p.heart_count,
    p.comment_count,
    p.view_count,
    p.progress_status,
    (EXISTS ( SELECT 1
           FROM public.post_hearts h
          WHERE ((h.post_id = p.id) AND (h.user_id = app.uid())))) AS hearted,
    p.image_url,
    p.region_code,
    (
        CASE
            WHEN ((p.authored_as)::text = 'business'::text) THEN NULL::character varying
            ELSE pr.address
        END)::character varying(100) AS author_address,
    p.edited_at,
    p.authored_as
   FROM ((public.posts p
     LEFT JOIN public.public_profiles pr ON ((pr.id = p.user_id)))
     LEFT JOIN public.business_profiles bp ON (((bp.user_id = p.user_id) AND ((bp.status)::text = 'approved'::text))))
  WHERE (((p.visibility_status)::text = 'visible'::text)
      OR (((p.visibility_status)::text = 'hidden_by_user'::text) AND (p.user_id = app.uid()))
      OR app.is_admin())
    AND (
      app.is_admin()
      OR app.uid() IS NULL
      OR NOT EXISTS (
        SELECT 1 FROM public.user_blocks b
        WHERE (b.blocker_id = app.uid() AND b.blocked_id = p.user_id)
           OR (b.blocked_id = app.uid() AND b.blocker_id = p.user_id)
      )
    );

-- 차단 조회가 피드 매 행마다 도므로 양방향 조회 인덱스를 둔다.
create index if not exists user_blocks_blocked_blocker_idx
  on public.user_blocks (blocked_id, blocker_id);
