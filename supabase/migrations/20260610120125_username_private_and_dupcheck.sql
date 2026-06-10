-- 아이디(username)를 로그인 전용 비공개 값으로 전환 + 가입 시 아이디 중복확인 RPC 추가.
--
-- 배경: username 은 로그인 식별자일 뿐 공개 핸들이 아니다(공개 표시는 nickname 담당).
-- 그런데 그동안 username 이 users 컬럼 SELECT 권한(anon/authenticated) + public_profiles 뷰로
-- 전체 공개·검색되고 있었다 → 전 사용자 아이디 수집(크리덴셜 스터핑 재료) 위험.
-- 이 마이그레이션은 username 노출을 차단하고, 본인 화면 표시는 login 응답(세션)으로만 처리한다.

-- 1) public_profiles 및 의존 뷰에서 username 노출 제거.
--    (컬럼 중간 제거는 CREATE OR REPLACE 불가 → CASCADE 후 동일 정의로 재생성.
--     의존 뷰들은 username 을 참조하지 않으므로 정의 변경 없이 그대로 복원.)
drop view if exists public.public_profiles cascade;

create view public.public_profiles with (security_invoker = on) as
  select id,
         nickname,
         user_type,
         profile_image_url,
         profile_image_thumbnail_url,
         address,
         is_location_verified,
         created_at
  from public.users u;

create view public.v_post_feed with (security_invoker = true) as
  select p.id,
         p.category,
         p.title,
         p.content,
         p.user_id,
         pr.nickname as author_nickname,
         pr.user_type as author_user_type,
         p.created_at,
         p.scheduled_at,
         p.display_address as location,
         p.heart_count,
         p.comment_count,
         p.view_count,
         p.progress_status,
         (exists (select 1 from post_hearts h where h.post_id = p.id and h.user_id = app.uid())) as hearted,
         p.image_url
  from posts p
    left join public_profiles pr on pr.id = p.user_id;

create view public.v_comment_feed with (security_invoker = true) as
  select c.id,
         c.post_id,
         c.user_id,
         c.content,
         c.created_at,
         pr.nickname as author_nickname
  from comments c
    left join public_profiles pr on pr.id = c.user_id
  where c.is_deleted = false;

create view public.v_chat_rooms with (security_invoker = true) as
  select r.id,
         r.last_message_preview,
         r.last_message_at,
         coalesce((select pr.nickname::text as nickname
                   from chat_room_members m2
                     join public_profiles pr on pr.id = m2.user_id
                   where m2.room_id = r.id and m2.user_id <> app.uid()
                   limit 1),
                  case when r.room_type::text = 'admin_inquiry'::text then '고객센터'::text
                       else '알 수 없음'::text end) as other_nickname,
         (select m2.user_id
          from chat_room_members m2
          where m2.room_id = r.id and m2.user_id <> app.uid()
          limit 1) as other_user_id,
         (select count(*) as count
          from chat_messages cm
          where cm.room_id = r.id and cm.is_deleted = false and cm.sender_id <> app.uid()
            and (m.last_read_message_id is null
                 or cm.created_at > (select lr.created_at from chat_messages lr where lr.id = m.last_read_message_id))) as unread_count
  from chat_room_members m
    join chat_rooms r on r.id = m.room_id
  where m.user_id = app.uid();

create view public.v_pawing with (security_invoker = true) as
  select pr.id as user_id,
         pr.nickname,
         pr.user_type,
         p.created_at
  from pawings p
    join public_profiles pr on pr.id = p.following_id
  where p.follower_id = app.uid();

create view public.v_pawmate with (security_invoker = true) as
  select pr.id as user_id,
         pr.nickname,
         pr.user_type,
         p.created_at,
         (exists (select 1 from pawings me where me.follower_id = app.uid() and me.following_id = p.follower_id)) as i_follow_back
  from pawings p
    join public_profiles pr on pr.id = p.follower_id
  where p.following_id = app.uid();

grant select on public.public_profiles, public.v_post_feed, public.v_comment_feed,
  public.v_chat_rooms, public.v_pawing, public.v_pawmate to anon, authenticated;

-- 2) 아이디 평문 직접 조회 차단 (users 테이블 username 컬럼 SELECT 권한 회수).
revoke select (username) on public.users from anon, authenticated;

-- 3) 로그인 시 본인 username 도 반환 (세션에 보관 → 본인 화면에서만 표시).
--    반환 타입 변경이라 DROP 후 재생성. 실행권한은 기존대로 service_role 전용.
drop function if exists public.login_user(text, text);
create function public.login_user(p_username text, p_password text)
returns table(id uuid, username text, nickname text, user_type text)
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  return query
  select u.id, u.username::text, u.nickname::text, u.user_type::text
  from public.users u
  where lower(u.username) = lower(p_username)
    and u.status = 'active'
    and u.password_hash = extensions.crypt(p_password, u.password_hash);
end;
$function$;
revoke all on function public.login_user(text, text) from public;
grant execute on function public.login_user(text, text) to service_role;

-- 4) 가입용 아이디 중복확인 RPC: 존재 여부 boolean 만 반환.
--    열거(enumeration) 방어 — 특정 문자열 1건 존재 여부만 알려줄 뿐 목록 조회는 불가.
create or replace function public.check_username_available(p_username text)
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
  select not exists (
    select 1 from public.users where lower(username) = lower(p_username)
  );
$function$;
revoke all on function public.check_username_available(text) from public;
grant execute on function public.check_username_available(text) to anon, authenticated;
