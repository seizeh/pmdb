-- 보안(MEDIUM #3): app.uid() 가 status='active' 사용자만 식별하도록 강화. 운영 적용 완료(형상 기록).
--
-- 배경: 기존 app.uid() 는 JWT sub 만 반환했다. login_user 는 이미 status='active' 만
--   토큰을 발급하지만, "로그인 후 정지/차단(admin_set_user_status)" 된 사용자는 발급된
--   토큰(exp 최대 7일)으로 계속 접근 가능했다(매 요청 status 재확인 부재).
--   is_admin() 과 동일하게 status 게이트를 넣어, 정지/차단이 app.uid 기반 모든
--   RLS·RPC 에 즉시 반영되도록 한다.
--
--   · SECURITY DEFINER: users 를 RLS 우회로 읽어 정책 재귀 방지(is_admin 과 동일 패턴).
--   · 비로그인(claims 없음)/비활성 → NULL 반환(anon 동작 유지).
--   · 함께 login Edge Function 토큰 exp 30일→7일 단축(유출 노출창 축소).
create or replace function app.uid()
returns uuid
language sql
stable
security definer
set search_path to ''
as $function$
  select u.id
  from public.users u
  where u.id = nullif(
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb) ->> 'sub',
      ''
    )::uuid
    and u.status = 'active'
$function$;
