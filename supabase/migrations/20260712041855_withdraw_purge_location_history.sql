-- 탈퇴(=위치정보 이용 동의 철회) 시 본인 위치 이력 즉시 파기.
-- 위치기반서비스 이용약관 제11조③·사업계획서 §3.4 "철회 시 법정 보존분(확인자료) 제외
-- 개인위치정보 지체 없이 파기" 이행. 기존 withdraw_account 는 users 프로필 좌표만 즉시
-- 파기하고 location_verifications 좌표 이력·photo_verifications 촬영 좌표는 6개월
-- retention-purge 까지 잔존하던 공백을 메운다.
--
-- 파기 범위:
--   - location_verifications: 행 삭제 (들어오는 FK 없음, 인증 상태는 users 에 있음)
--   - photo_verifications: 촬영 좌표(shot_*)만 스크럽 — pets/posts 가 FK 로 참조 중일 수
--     있어 행 삭제 불가(retention_purge_batch 와 동일한 이유). AI 판별 결과는 위치정보가
--     아니므로 유지.
--   - posts.actual_lat/lng: 즉시 스크럽 (현재 앱은 미수집이라 사실상 no-op 방어선)
--   - app.location_usage_logs(확인자료)는 위치정보법 제16조②에 따라 6개월 보존 후 파기 — 유지.
create or replace function public.withdraw_account()
returns void language plpgsql security definer set search_path to '' as $function$
declare
  v_me uuid := app.uid();
  v_tag text;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  v_tag := substr(replace(v_me::text, '-', ''), 1, 10);

  -- 부정이용 방지 분리보관 (아이디·전화번호, 30일 후 cron 파기)
  insert into app.withdrawn_users (user_id, username, phone)
  select u.id, u.username, u.phone from public.users u where u.id = v_me
  on conflict (user_id) do nothing;

  -- 개인정보 익명화 + 상태 전환(token_version 증가 + status 변경 → 모든 세션 즉시 무효)
  update public.users set
    username = 'del_' || v_tag,
    nickname = '탈퇴회원' || v_tag,
    password_hash = '!',
    phone = null,
    phone_verified = false,
    profile_image_url = null,
    profile_image_thumbnail_url = null,
    profile_image_mime_type = null,
    profile_image_file_size = null,
    address = null,
    latitude = null,
    longitude = null,
    is_location_verified = false,
    region_code = null,
    activity_radius_m = null,
    push_enabled = false,
    marketing_opt_in = false,
    unread_notification_count = 0,
    unread_chat_count = 0,
    status = 'deleted',
    deleted_at = now(),
    token_version = token_version + 1
  where id = v_me and status = 'active';
  if not found then
    raise exception 'not_active_account' using errcode = 'P0001';
  end if;

  -- 개인위치정보 이력 즉시 파기 (약관 제11조③ — 확인자료는 법정 6개월 보존이라 제외)
  delete from public.location_verifications where user_id = v_me;
  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where user_id = v_me
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);
  update public.posts
     set actual_lat = null, actual_lng = null
   where user_id = v_me
     and (actual_lat is not null or actual_lng is not null);

  -- 세션·푸시·알림 정리
  delete from app.refresh_tokens where user_id = v_me;
  delete from public.device_tokens where user_id = v_me;
  delete from public.notifications where user_id = v_me;
  delete from public.notification_preferences where user_id = v_me;

  -- 소셜 관계 정리 (팔로우 양방향)
  delete from public.pawings where follower_id = v_me or following_id = v_me;

  -- 반려동물: 내가 대표 보호자인 펫은 삭제 처리, 내 보호자 멤버십 제거
  update public.pets set pet_status = 'deleted', updated_at = now()
   where primary_guardian_id = v_me and pet_status <> 'deleted';
  delete from public.pet_guardians where user_id = v_me;

  -- 채팅: 모든 방에서 나가기(목록 숨김 · 상대는 전송 불가 안내)
  update public.chat_room_members set left_at = now(), updated_at = now()
   where user_id = v_me and left_at is null;
end $function$;

revoke all on function public.withdraw_account() from public, anon;
grant execute on function public.withdraw_account() to authenticated;
