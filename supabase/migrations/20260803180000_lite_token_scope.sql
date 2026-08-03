-- 간이 후기 토큰의 권한 범위를 실제로 '후기만' 으로 좁힌다.
--
-- ── 무엇이 문제였나 ────────────────────────────────────────────────────────
-- signup-lite 는 같은 번호의 **기존 계정을 그대로 돌려준다**(0029 의 의도 — 방문
-- 회차 visit_no 가 끊기지 않게). 정지·탈퇴만 거부하므로 `active` 정식 회원도 반환된다.
-- 그리고 엣지 함수가 그 계정의 **실제 token_version 을 정확히 stamp** 해 서명한다
-- (안 하면 tv 가 오른 계정이 즉시 잠기므로 이것 자체는 필요한 처리다).
--
-- 그 결과 발급되는 15분 토큰은 app.uid() 의 조건(status='active' AND tv 일치)을
-- **완전히 충족한다.** 즉 후기가 아니라 채팅·게시글·펫·프로필 전부에 통한다.
--
-- 함수 주석과 docs/supabase-api.md 는 정반대를 적고 있었다 —
--   "이 토큰으로는 후기 작성 외에 아무것도 못 한다 — 계정이 status='lite' 라"
-- status='lite' 인 **신규** 계정에만 참이고, 기존 정식 회원에는 거짓이다.
-- 방어의 근거가 "계정 상태"에 있었는데 그 상태가 경로마다 다른 값을 가질 수 있었다.
--
-- ── 왜 심각한가 ───────────────────────────────────────────────────────────
-- 전제는 그 번호로 오는 SMS 를 볼 수 있어야 한다는 것이고(send-phone-code 는
-- purpose='review' 에 계정 존재를 검사하지 않는다 — 정식 회원도 간이 경로로 후기를
-- 써야 하므로 phone_taken 에 막히면 안 된다는 0029 의 의도된 설계), 그 문턱은
-- 비밀번호 재설정과 같다. 차이는 **소란스러움**이다:
--
--   재설정 — 비번이 바뀌고 tv 가 오르고 refresh 가 전량 회수된다. 피해자가 즉시
--            잠기므로 그 자리에서 알아챈다.
--   이 경로 — auth_logs 미기록, 새 기기 로그인 알림 없음, 기존 세션 유지, 비번 그대로.
--            **아무 흔적도 남지 않는다.**
--
-- 통신사 번호 재배정처럼 "남의 번호를 합법적으로 갖게 되는" 경우가 현실에 있으므로
-- 조용한 쪽을 열어 두면 안 된다.
--
-- ── 조치 ──────────────────────────────────────────────────────────────────
-- 권한 판정을 **계정 상태가 아니라 토큰 자신**에 싣는다. signup-lite 가 발급하는
-- 토큰에 `lite: true` 클레임을 박고, app.uid() 가 그 클레임을 거부한다.
-- app.uid_lite() 는 그대로 받아들이므로 후기 3종(add_facility_review ·
-- facility_review_by_id · facility_reviews_of)은 계속 동작한다.
--
-- 상태가 아닌 클레임으로 판정하는 이유: 같은 계정이 경로에 따라 다른 권한을 가져야
-- 하는데, 계정 행은 경로를 모른다. 토큰은 안다.

-- ── 1) app.uid() — lite 클레임 토큰 거부 ──────────────────────────────────
-- 운영 현재 정의를 기준으로 조건 한 줄만 덧붙인다(공유 함수 재정의로 남의 변경을
-- 유실시키지 않기 위해 — 20260718190000 의 재발 방지 원칙).
--
-- 텍스트 비교(<> 'true')로 쓴 이유: ->>'lite' 를 ::boolean 으로 캐스팅하면 값이
-- 예상 밖 문자열일 때 **캐스트 오류**가 나고, 그 오류는 RLS 정책 안에서 터지므로
-- "거부" 가 아니라 "쿼리 실패" 가 된다. 클레임이 없으면 NULL → coalesce → '' → 통과.
create or replace function app.uid()
returns uuid
language sql
stable security definer
set search_path = ''
as $$
  select u.id
  from public.users u
  where u.id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'sub','')::uuid
    and u.status = 'active'
    and u.token_version = coalesce(
      ((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'tv')::int, 0)
    -- 간이 후기 전용 토큰은 여기까지 오면 안 된다(signup-lite 가 lite=true 를 박는다).
    and coalesce(
      (nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'lite', '') <> 'true'
$$;

comment on function app.uid() is
  '인증된 사용자 uuid. status=active + token_version 일치 + 간이(lite) 토큰이 아닐 것.';

-- ── 2) 간이 세션의 후기 사진 업로드 ───────────────────────────────────────
-- media 버킷의 쓰기 정책은 app.uid() 기준이라, **status=lite 인 진짜 간이 계정은
-- 지금도 사진을 못 올린다**(app.uid() 가 NULL → 폴더명 비교가 NULL → 거부).
-- 앱은 올릴 수 있다고 가정한다 — facility_review_screen 의
-- "인증을 마쳤으니 이제 Storage 에 쓸 수 있다" 주석이 그 기대다.
-- 즉 간이 후기의 사진 첨부는 **이미 깨져 있었고**, 정식 회원이 간이 경로로 들어온
-- 경우에만 (위 결함 때문에) 우연히 동작하고 있었다.
--
-- 1) 을 넣으면 그 우연도 사라지므로, 같은 마이그레이션에서 의도된 동작을 만들어 준다.
-- 범위는 최소로 — 자기 폴더 아래 `facility_review/` 한 칸만.
create policy "media lite review insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = (app.uid_lite())::text
    and (storage.foldername(name))[2] = 'facility_review'
  );

notify pgrst, 'reload schema';
