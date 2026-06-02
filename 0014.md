-- ============================================================================
-- PawMate · 0014 · 비활성 사용자 공개 + unread drift 보정 + 정책 명시
-- ----------------------------------------------------------------------------
-- [실제 결함 수정] #6 탈퇴(inactive) 사용자의 안전 컬럼이 RLS 로 차단돼서
--   과거 콘텐츠 JOIN 시 nickname/profile_image 가 NULL 로 떨어지는 문제 해결.
-- [안전망 추가]   #5 unread_chat_count / unread_notification_count drift 복구
--   용 RPC. 앱 진입/재연결 시 호출해 캐시를 source-of-truth 로 재계산.
-- [정책 명시]     #3·#4·#7 운영 정책을 COMMENT 로 못박아 향후 혼동 방지.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) users_select 정책 완화 : inactive 허용, suspended 만 차단
--    민감 컬럼은 0006 의 컬럼 단위 GRANT 로 이미 막혀 있어 노출 위험 없음.
--    inactive 사용자도 nickname/profile_image 만 공개 → 과거 댓글·채팅·리뷰의
--    작성자 표시가 NULL 로 깨지지 않음. 앱은 status='inactive' 면 "(탈퇴한 사용자)"
--    라벨로 덮어쓰도록 처리하는 게 일반적.
-- ---------------------------------------------------------------------------
drop policy if exists users_select on public.users;
create policy users_select on public.users
  for select using (
    status <> 'suspended'   -- 정지/금지된 사용자만 비공개
    or id = app.uid()       -- 본인은 status 무관 전체 조회
    or app.is_admin()       -- 관리자 전체 조회
  );

-- ---------------------------------------------------------------------------
-- 2) app.reconcile_unread_counts(p_user_id) : 미읽음 캐시 drift 보정 RPC
--    호출 시점: 앱 진입, 재연결 후, 다중 기기 동기화 직후 등.
--    권한: 본인 호출만 허용(admin/service_role 은 임의 user_id 호출 가능).
-- ---------------------------------------------------------------------------
create or replace function app.reconcile_unread_counts(p_user_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid;
  v_chat     int := 0;
  v_notif    int := 0;
  r          record;
  v_per      int;
  v_read_ts  timestamptz;
  v_read_id  uuid;
begin
  v_user := coalesce(p_user_id, app.uid());
  if v_user is null then
    raise exception 'reconcile_unread_counts: 대상 사용자가 지정되지 않았습니다';
  end if;

  -- 본인이 아닌 다른 사용자 대상 호출은 관리자/시스템(=app.uid() NULL) 한정
  if app.uid() is not null and app.uid() <> v_user and not app.is_admin() then
    raise exception 'reconcile_unread_counts: 본인 카운트만 보정할 수 있습니다';
  end if;

  -- (1) 미읽음 채팅 합계: 방별 last_read_message_id 기준 (created_at, id) 튜플 비교
  for r in
    select room_id, last_read_message_id
      from public.chat_room_members
     where user_id = v_user
  loop
    if r.last_read_message_id is null then
      select count(*) into v_per
        from public.chat_messages msg
       where msg.room_id   = r.room_id
         and msg.sender_id <> v_user
         and msg.is_deleted = false;
    else
      select created_at, id into v_read_ts, v_read_id
        from public.chat_messages
       where id = r.last_read_message_id;
      select count(*) into v_per
        from public.chat_messages msg
       where msg.room_id   = r.room_id
         and msg.sender_id <> v_user
         and msg.is_deleted = false
         and (msg.created_at, msg.id) > (v_read_ts, v_read_id);
    end if;
    v_chat := v_chat + coalesce(v_per, 0);
  end loop;

  -- (2) 미읽음 알림 합계
  select count(*) into v_notif
    from public.notifications n
   where n.user_id = v_user and n.is_read = false;

  -- (3) 캐시 갱신
  update public.users
     set unread_chat_count         = v_chat,
         unread_notification_count = v_notif
   where id = v_user;
end;
$$;
grant execute on function app.reconcile_unread_counts(uuid) to authenticated, service_role;

comment on function app.reconcile_unread_counts(uuid) is
  '미읽음 채팅/알림 카운트 캐시를 source-of-truth(메시지/알림 테이블) 기준으로 재계산. 앱 진입·재연결·다중기기 동기화 직후 호출 권장';

-- ---------------------------------------------------------------------------
-- 3) 정책 COMMENT 로 명시 (향후 혼동 방지)
-- ---------------------------------------------------------------------------

-- #4 알림 집계 모델
comment on column public.notifications.aggregated_count is
  '병합된 이벤트 수. INSERT ON CONFLICT DO UPDATE 의 행락(row lock)으로 race-safe. 절대 시점 정확성이 아니라 결국정확(eventual consistency) 모델';

-- #3 토글 테이블의 삭제 정책
comment on table public.post_likes is
  '하트(좋아요). 토글 = 하드 DELETE(soft delete 사용 안 함). UNIQUE(post_id, user_id) 재생성 자유.';
comment on table public.pawings is
  '팔로우(Pawing). 언팔로우 = 하드 DELETE(soft delete 사용 안 함). UNIQUE(follower_id, following_id) 재생성 자유.';

-- 초대 재시도 정책
comment on table public.pet_guardian_invites is
  '공동보호자 초대/요청. UNIQUE 는 status=pending 한정 partial → 거절/만료 후 재초대 가능.';

-- 지원 재시도 정책
comment on table public.applications is
  '게시글 지원. UNIQUE(post_id, applicant_id) 풀제약 → 한 게시글에 한 사용자는 1회만(취소·거절 후에도 재지원 불가). 정책 변경 시 partial unique 로 전환 필요.';

-- #7 신고 대상 삭제 시 정책
comment on table public.reports is
  '신고. target 은 polymorphic 이며 FK 없음. 대상이 삭제되더라도 신고 행은 감사 기록으로 보존(cascade 없음, orphan 허용).';
