-- 아무 일도 하지 않으면서 오해를 만드는 SELECT 그랜트 회수 (0032 §7.11).
--
-- `phone_verifications`·`photo_verifications`·`dong_centroids` 는 **RLS 가 켜져 있고
-- 정책이 0개**다. 정책 없는 RLS 는 전면 거부이므로, SELECT 그랜트가 있어도 클라이언트는
-- 항상 0행을 받는다. 읽기는 전부 SECURITY DEFINER RPC 가 한다.
--
-- 즉 이 그랜트들은 **효과가 없다.** 그런데 권한 목록만 보면 "읽어도 되는 표" 로 보인다.
-- `phone_verifications` 는 OTP 코드를 담으므로 그 오해가 특히 비싸다 — 훗날 누군가
-- RLS 를 끄거나(또는 정책을 하나 추가하면서 그랜트를 근거로 삼으면) 그 순간 열린다.
-- 방어를 한 겹 더 두는 게 아니라, **틀린 신호를 지우는** 작업이다.
--
-- 안전 확인(2026-08-05):
--   · 이 세 테이블을 참조하는 **INVOKER 함수·뷰·RLS 정책이 하나도 없다** — 전부 정의자
--     경로다. 정의자는 그랜트와 무관하게 동작한다.
--   · 앱 코드에도 직접 조회가 없다(주석에 이름만 등장).
--   · service_role 은 건드리지 않는다(엣지 함수·크론이 계속 쓴다).
--
-- 종전 동작은 "0행", 이후 동작은 "42501" 이다. 부르는 곳이 없으므로 차이가 드러날 곳도
-- 없지만, 굳이 고르자면 **조용한 0행보다 시끄러운 거부가 낫다** — 실수로 이 표를 읽는
-- 코드가 생기면 바로 알 수 있다.
revoke select on public.phone_verifications  from anon, authenticated;
revoke select on public.photo_verifications  from anon, authenticated;
revoke select on public.dong_centroids       from anon, authenticated;
