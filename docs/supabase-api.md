# PawMate Supabase — API(Edge Functions) 문서

- **조사일**: 2026-07-02 — 로컬 소스(`supabase/functions/`) + 원격 배포 상태 대조
- **짝 문서**: [supabase-db.md](supabase-db.md) — DB 스키마/로직 레퍼런스

- 소스 위치: `/Users/seize_h/StudioProjects/pmdb/supabase/functions/`
- Supabase 프로젝트: `vyatppuxmpulqtxevfpk` (PAWMATE, region ap-northeast-2)
- 런타임: Deno (Edge Runtime), 모든 함수는 `POST` + `OPTIONS`(CORS preflight)만 허용. 그 외 메서드는 `405 { error: "method_not_allowed" }`.
- 클라이언트(Flutter 앱 `pmdart`)는 publishable(anon) 키만 사용. `service_role` 키와 `JWT_SECRET`은 Edge Function 시크릿으로만 존재.
- 관련 설계 문서: `/Users/seize_h/StudioProjects/pmdb/docs/refresh-token-flow-design.md` (refresh 토큰 v1 "thin full" 설계 + 1단계 구현 노트)

## 1. 개요

| 슬러그 | 용도 | 인증 | verify_jwt(배포) | 배포 상태 |
|---|---|---|---|---|
| `send-phone-code` | 전화 인증번호(6자리) 발급 + Solapi SMS 발송 | 없음 (전화번호 자체 레이트리밋) | **true** (의도적 — 남용 게이트, §6) | ACTIVE v12 |
| `verify-phone-code` | 전화 인증번호 검증 (is_used 처리) | 없음 | **true** (의도적 — 남용 게이트, §6) | ACTIVE v12 |
| `signup` | 회원가입 (전화 인증 완료 번호만) | 없음 | **true** (의도적 — 남용 게이트, §6) | ACTIVE v10 |
| `login` | ID/비번 로그인 → access JWT(+refresh) 발급 | 없음 (토큰 발급 단계) | false | ACTIVE v18 |
| `refresh` | refresh 토큰 회전 → 새 access+refresh 쌍 | refresh 토큰 (바디) | false | ACTIVE v6 |
| `logout` | refresh family 전체 회수 (멱등) | refresh 토큰 (바디) | false | ACTIVE v3 |
| `change-password` | 비밀번호 변경 + 전 세션 무효화 + 현 기기 재발급 | 커스텀 JWT Bearer | false | ACTIVE v6 |
| `reset-password` | 전화 OTP 인증 후 비밀번호 재설정 | 없음 (선행 전화 인증 필요) | false | ACTIVE v3 |
| `verify-location` | GPS 현장 동네(행정동) 인증 | 커스텀 JWT Bearer | false | ACTIVE v10 |
| `verify-post-photo` | 게시글 사진 동일개체 매칭 + 라이브니스(Gemini) | 커스텀 JWT Bearer | false | ACTIVE v9 |
| `enroll-pet-identity` | 펫 신원 등록 (임무 영상 → AI 검증 → 기준 프레임) | 커스텀 JWT Bearer | false | ACTIVE v8 |
| `search-petcafe` | 애견카페 실시간 검색 (네이버 지역검색 프록시) | 커스텀 JWT Bearer | false | ACTIVE v9 |
| `resolve-region` | 좌표 → 행정동 역지오코딩 (부수효과 없음) | 커스텀 JWT Bearer | false | ACTIVE v3 |
| `sync-dong-centroids` | 행정동 중심좌표 채우기 (지오코딩 배치, 멱등) | 커스텀 JWT Bearer | false | ACTIVE v3 |
| `send-push` | pending 알림 FCM(HTTP v1) 발송 | `x-push-secret` 공유 시크릿 | false | ACTIVE v3 |

총 15개 함수. 로컬 소스 15개 = 원격 배포 15개 (1:1 일치, 누락/고아 없음).

참고: `supabase/functions/supabase/` 디렉터리는 **함수가 아니라** Supabase CLI가 남긴 `.temp/linked-project.json`(프로젝트 링크 캐시) 아티팩트다. `verify-phone-code/supabase/.temp/`에도 동일 아티팩트가 하나 더 있다(함수 폴더 안에서 CLI를 실행한 흔적).

인증 모델 요약: Supabase Auth(GoTrue)를 쓰지 않는 **완전 커스텀 인증**이다. `login`이 HS256 access JWT(프로젝트 JWT Secret으로 서명, `sub/role=authenticated/aud=authenticated/iss=supabase/tv` 클레임)를 직접 발급하고, PostgREST가 네이티브로 검증하며 `app.uid()`가 `status='active'` + `token_version(tv)` 일치를 매 요청 게이트한다. 엣지 함수들은 게이트웨이 `verify_jwt`를 끄고 `_shared/auth.ts`(또는 각 함수 내 동일 로직 복제본)로 **수동 검증**한다 — 함수별 `verify_jwt` 값은 `supabase/config.toml`(2026-07-02 추가)에 명시되어 재배포 시 결정론적으로 적용된다(12개 false, 전화인증/가입 3개만 true). DB 접근은 전부 `service_role` 클라이언트 경유(관련 테이블·RPC에 anon/authenticated GRANT 없음).

## 2. 공용 모듈 (_shared)

### 2.1 `_shared/auth.ts` — 커스텀 JWT/refresh 토큰 유틸

파일: `/Users/seize_h/StudioProjects/pmdb/supabase/functions/_shared/auth.ts`

- **`signAccess(sub, tv, ttlSec, secret)`** — HS256 access JWT 서명. 페이로드: `{ sub, role:"authenticated", aud:"authenticated", iss:"supabase", iat, exp, tv }`. 서명키는 시크릿 `JWT_SECRET`(= Supabase 프로젝트 JWT Secret) → PostgREST가 이 토큰을 네이티브로 검증 가능.
- **`verifyAccess(token, secret)`** — 수동 검증: ① 3파트 구조 확인 ② 헤더 `alg === "HS256"` 고정 확인(alg-confusion/`none` 공격 방어) ③ HMAC 서명 검증 ④ `exp` 만료 확인. 실패 시 `null`, 성공 시 클레임 객체 반환.
- **`bearer(req)`** — `Authorization: Bearer <token>` 파싱.
- **`clientUa(req)`** — `user-agent`를 300자로 절단(refresh_tokens.user_agent 저장용, 비대화 방지).
- **`clientIp(req)`** — 레이트리밋 키용 IP. 신뢰 프록시 헤더(`cf-connecting-ip` → `x-real-ip`) 우선, `x-forwarded-for` leftmost는 클라 주입 가능(스푸핑)이라 최후 폴백. 식별 불가 시 `null` → 호출부는 IP 버킷을 건너뜀(전역 'unknown' 버킷 오작동 방지). IP 제한은 보조 방어선일 뿐, 1차 방어는 스푸핑 불가한 토큰해시·계정 버킷.
- **`rateLimited(supabase, key, max, windowSeconds)`** — RPC `rate_limit_hit(p_key, p_max, p_window_seconds)` 1회 소모. `true`=제한 초과(차단). **리미터 자체 오류는 fail-open**(가용성 우선 — 로그인/갱신을 막지 않음). `rate_limit_hit`은 ~2% 확률로 만료행을 기회적으로 삭제(백스톱).
- **`sha256Hex(input)`** — refresh 토큰 저장용 해시(원문 저장 금지).
- **`randomToken(bytes=32)`** — 불투명 refresh 토큰 원문(256bit, `crypto.getRandomValues` → base64url).
- **상수**: `ACCESS_TTL_CAPABLE = 8h`(refresh 지원 클라), `ACCESS_TTL_LEGACY = 30d`(레거시, 추후 축소 예정), `REFRESH_GRACE_SECONDS = 30`.

주의: `verify-location`, `verify-post-photo`, `enroll-pet-identity`, `search-petcafe`, `resolve-region`, `sync-dong-centroids`는 이 모듈 대신 **각자 파일 안에 동일한 JWT 검증 로직(`getUidFromJwt`)을 복제**해 갖고 있다(기능 동일 — 단, `alg` 헤더 고정 확인은 없음, `sub`/`exp`만 사용). `signup`, `reset-password`, `send-push`는 CORS/json 헬퍼도 자체 복제한다(`_shared/cors.ts` 미사용).

### 2.2 `_shared/cors.ts` — CORS + JSON 응답 헬퍼

- `corsHeaders`: `Access-Control-Allow-Origin: $ALLOW_ORIGIN`(미설정 시 `*`), 허용 헤더 `authorization, x-client-info, apikey, content-type, x-client-refresh`, 허용 메서드 `POST, OPTIONS`.
- `json(body, status=200)`: CORS 헤더 + `Content-Type: application/json` Response 생성.

### 2.3 `_shared/solapi.ts` — Solapi(구 CoolSMS) SMS 클라이언트

- 인증: HMAC-SHA256 서명 헤더 — `signature = HMAC_SHA256(apiSecret, date + salt)`(hex), `Authorization: HMAC-SHA256 apiKey=..., date=..., salt=..., signature=...`.
- 발송: `POST https://api.solapi.com/messages/v4/send`, 바디 `{ message: { to, from, text } }`. 발신번호(`from`)는 Solapi 콘솔 사전등록 번호여야 함(국내 규정).
- **`normalizePhone(raw)`** — 숫자만 남기고 `+82`/`82` 접두를 `0`으로 변환(예: `+821012345678` → `01012345678`).
- **`loadSolapiConfig()`** — `SOLAPI_API_KEY` / `SOLAPI_API_SECRET` / `SOLAPI_SENDER` 로드, 하나라도 없으면 throw.
- **`sendSms(cfg, to, text)`** — `{ ok, status, body }` 반환.

## 3. 인증/토큰 수명주기 흐름

### 3.1 토큰 모델

| 토큰 | 형식 | 수명 | 서버 저장 | 무효화 수단 |
|---|---|---|---|---|
| access | HS256 JWT (`JWT_SECRET` 서명, `sub/role/aud/iss/iat/exp/tv`) | capable 8h / 레거시 30d | 없음(무상태) | `users.token_version` bump(즉시) 또는 만료 |
| refresh | 불투명 랜덤 256bit (base64url) | 롤링 30일 / family 절대 90일 | `app.refresh_tokens`에 **SHA-256 해시만** | 회수(회전 재사용 탐지/로그아웃/정지/비번변경) |
| session-version | `users.token_version` (int) | — | — | bump = 그 사용자의 모든 access 즉시 무효 |

`app.uid()`가 매 요청 `status='active'` + `token_version == tv 클레임`(클레임 없음=0, 레거시 구제)을 검사하므로, access 수명이 길어도(8h/30d) `token_version`++ 한 방으로 즉시 전역 차단된다. **새로 발급되는 모든 토큰(레거시 분기 포함)에 현재 tv를 반드시 stamp**한다(미stamp 시 tv>0 사용자가 로그인 즉시 잠김).

### 3.2 회원가입 흐름 (전화 인증 선행)

1. `send-phone-code` `{ phone, purpose:'signup' }` → 6자리 코드 SMS 발송(5분 유효, 같은 번호+목적 60초 1회).
2. `verify-phone-code` `{ phone, code, purpose:'signup' }` → 최신 미사용·미만료 코드 일치 시 `is_used=true`.
3. `signup` `{ username, password, nickname, user_type, phone, marketing_opt_in? }` → 엣지에서 argon2id 해싱(_shared/passwords) 후 `signup_user` RPC(SECURITY DEFINER, users INSERT + 약관 동의 시각 기록). 인증 안 된 번호면 `phone_not_verified`(403).
4. 이후 `login`으로 토큰 획득.

### 3.3 로그인 → 갱신 → 로그아웃

1. **login** `{ username, password }` (+헤더 `x-client-refresh: 1` = refresh 지원 capability):
   - capable: access 8h(tv 포함) + refresh 발급(새 family; `login_issue_refresh` RPC — 다른 활성 세션 있으면 "새 기기 로그인" 알림 생성, 현재 token_version 반환).
   - 레거시(헤더 없음): access 30일만(무중단 하위호환), tv는 users에서 직접 조회해 stamp.
2. **매 API 요청**: 클라가 access 만료 임박(skew 60s) 감지 시 단일비행으로 `refresh` 선호출(앱 `accessToken` 콜백 훅).
3. **refresh** `{ refresh_token }` → `rt_rotate` RPC가 **원자적 회전**(구 토큰 `revoked_at` 마킹 + 같은 family로 신규 발급, `UPDATE ... WHERE revoked_at IS NULL` 경쟁 가드):
   - `rotated` 또는 `grace`(회수 후 30초 내 재사용 = 모바일 응답 유실 재시도로 간주, family 회수 안 함) → 새 access(8h)+refresh 쌍.
   - `invalid`/`expired`/`inactive`/`reuse_revoked`(30초 초과 재사용 = 탈취로 판단, family 회수) → 클라에는 일괄 `invalid_refresh` 401(토큰 상태 구분 비노출). 클라는 401 시 세션 clear → 로그인 화면.
   - 수용된 트레이드오프: grace 30초 창 안에서 탈취 토큰도 유효 쌍을 받을 수 있음 — `refresh:tok` 해시 레이트리밋(20/분)으로 남용 캡.
4. **logout** `{ refresh_token }` → `rt_revoke_family` RPC로 해당 family 전체 회수. 멱등, 항상 200(존재 여부 비노출).

### 3.4 비밀번호 변경/재설정

- **change-password** (로그인 상태): access JWT 검증 → `get_password_hash` 로 현재 해시 조회, **엣지에서 현재 비번 검증**(argon2id/bcrypt 겸용) → 새 비번 argon2id 해싱 → `change_password_and_rotate(현재해시 CAS, 새해시, …)` RPC **단일 트랜잭션**: 세션(status+tv) 검증 → 해시 CAS 갱신 → `token_version`++(모든 기존 access 즉사) + refresh 전량 회수 → **현재 기기용 새 family 발급**(현재 기기 로그아웃 방지). 응답으로 새 access+refresh 쌍 반환. 중간 실패 시 전체 롤백.
- **reset-password** (비로그인, 비번 분실): `send-phone-code`/`verify-phone-code`를 `purpose:'password_reset'`으로 선행 → `reset-password { phone, new_password }` → 엣지에서 argon2id 해싱 후 `reset_password_user` RPC가 **30분 내 인증 완료된 번호**인지 확인 후 해시 갱신 + 전 세션 무효화(token_version bump + refresh 회수).

### 3.5 정지/차단 연동

- 정지/차단(`status` 비active): access는 `app.uid()` status 게이트로 즉시 차단, refresh는 `rt_rotate`가 `inactive` 반환(+회수).

## 4. 함수 상세

### send-phone-code

- **엔드포인트**: `POST /functions/v1/send-phone-code` — verify_jwt=**true** (config.toml로 고정. publishable 키 요구를 얇은 남용 게이트로 사용, §6 참고)
- **인증**: 없음(로그인 전 단계). 남용은 자체 레이트리밋으로 방어.
- **요청 바디**: `{ phone: string(필수, 정규화 후 /^01\d{8,9}$/), purpose?: 'signup' | 'password_reset' (기본 'signup') }`. 전화번호는 `normalizePhone`으로 정규화(+82→0).
- **응답**:
  - 200 `{ ok: true, expires_in_sec: 300 }`
  - 400 `invalid_json` / `invalid_phone` / `invalid_purpose`
  - 429 `{ error: "rate_limited", retry_after_sec: 60 }`
  - 500 `server_misconfigured`(Solapi env 누락) / `internal_error`
  - 502 `{ error: "sms_send_failed", detail: <Solapi 응답> }`
- **내부 로직**: ① `phone_verifications` 테이블에서 같은 phone+purpose로 최근 60초 내 발급 이력 count → 있으면 429 ② 6자리 코드 생성(`crypto.getRandomValues` mod 1e6) + `phone_verifications` INSERT(`expires_at = now+5분`) ③ Solapi로 SMS 발송(`[PawMate] 인증번호 XXXXXX (5분 내 입력)`). DB는 service_role 전용(RLS 정책 없음).
- **시크릿/환경변수**: `SOLAPI_API_KEY`, `SOLAPI_API_SECRET`, `SOLAPI_SENDER`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 코드 TTL 5분. 동일 번호+목적 60초 1회 발급 제한.

### verify-phone-code

- **엔드포인트**: `POST /functions/v1/verify-phone-code` — verify_jwt=**true** (config.toml로 고정, §6)
- **인증**: 없음.
- **요청 바디**: `{ phone: string(필수, /^01\d{8,9}$/ 정규화 후), code: string(필수, /^\d{6}$/), purpose?: 'signup' | 'password_reset' (기본 'signup') }`
- **응답**:
  - 200 `{ verified: true }`
  - 400 `invalid_json` / `invalid_phone` / `invalid_code` / `invalid_purpose` / `{ verified: false, error: "code_mismatch_or_expired" }`
  - 500 `internal_error`
- **내부 로직**: `phone_verifications`에서 phone+purpose의 **미사용(is_used=false)·미만료(expires_at>now) 최신 1건** 조회 → 코드 일치 시 `is_used=true` UPDATE(재사용 방지). service_role 전용.
- **시크릿**: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 최신 코드 1건만 유효. 코드 사용 후 재사용 불가. 인증 결과는 `signup`(무기한? — `signup_user` 검증 로직에 따름) / `reset-password`(30분 창)에서 소비.

### signup

- **엔드포인트**: `POST /functions/v1/signup` — verify_jwt=**true** (config.toml로 고정, §6)
- **인증**: 없음(로그인 전). 남용은 전화 인증 선행 + 유니크 제약으로 방어.
- **요청 바디** (모두 필수):
  - `username: string` — `/^[A-Za-z0-9]{4,20}$/`
  - `password: string` — 8자 이상 + 영문 포함 + 숫자 포함
  - `nickname: string` — 1~20자
  - `user_type: string` — `pet_owner | no_pet | business`
  - `phone: string` — 정규화 후 `/^01\d{8,9}$/`
- **응답**:
  - 200 `{ ok: true, user_id: <uuid> }`
  - 400 `invalid_json` / `invalid_username` / `invalid_password` / `invalid_nickname` / `invalid_user_type` / `invalid_phone`
  - 403 `phone_not_verified`
  - 409 `username_taken` / `nickname_taken` / `phone_taken`
  - 500 `internal_error`
- **내부 로직**: 입력 검증 → **argon2id 해싱(_shared/passwords, hash-wasm)** → `signup_user` RPC(SECURITY DEFINER) 호출 — 전화 인증 완료 확인, `users` INSERT(terms_agreed_at·마케팅 동의 기록). RPC가 raise한 커스텀 에러코드를 HTTP 코드로 매핑.
- **시크릿**: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`). CORS/json 헬퍼를 파일 내 자체 정의(_shared 미사용).
- **정책**: `verify-phone-code(purpose='signup')` 완료된 번호만 가입 가능.

### login

- **엔드포인트**: `POST /functions/v1/login` — verify_jwt=false
- **인증**: 없음(토큰 발급 단계). 선택 헤더 `x-client-refresh: 1`(refresh 지원 capability 선언).
- **요청 바디**: `{ username: string(필수, trim), password: string(필수) }`
- **응답**:
  - 200 `{ ok: true, token: <access JWT>, refresh_token?: <불투명 토큰, capable만>, expires_in: 28800|2592000, user: { id, username, nickname, user_type } }`
  - 400 `invalid_json` / `missing_fields`
  - 401 `invalid_credentials`
  - 429 `rate_limited`
  - 500 `server_misconfigured`(JWT_SECRET 미설정) / `internal_error`
- **내부 로직**: ① 레이트리밋 — 계정 `login:user:<username소문자>` 10회/5분(1차) + IP `login:ip:<ip>` 20회/분(보조, IP 식별 시만) ② `get_login_user` RPC(service_role)로 사용자·해시 조회(status='active'만) 후 **엣지에서 비번 검증**(argon2id/bcrypt 겸용, 미존재 계정은 더미 해싱으로 타이밍 균등화) — bcrypt(레거시) 성공 시 `update_password_hash`(CAS)로 argon2id 점진 재해싱 ③ capable이면 `randomToken()` 생성 → `login_issue_refresh` RPC(p_user, p_token_hash=sha256, p_user_agent) — 새 family 발급 + 다른 활성 세션 있으면 새 기기 로그인 알림, 현재 `token_version` 반환. 레거시면 `users.token_version` 직접 SELECT ④ `signAccess(uid, tv, ttl, JWT_SECRET)` — capable 8h / 레거시 30d. tv 조회 실패는 500(0으로 추측 stamp 시 tv>0 사용자 즉시 잠김 방지).
- **시크릿**: `JWT_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 위 레이트리밋(리미터 오류 fail-open). 계정 버킷은 표적 락아웃 여지 있음(수용된 절충).

### refresh

- **엔드포인트**: `POST /functions/v1/refresh` — verify_jwt=false (만료된 access를 갱신하는 단계라 access 검증 안 함)
- **인증**: refresh 토큰(바디) 자체가 크리덴셜.
- **요청 바디**: `{ refresh_token: string(필수) }`
- **응답**:
  - 200 `{ ok: true, token, refresh_token: <새 토큰>, expires_in: 28800 }`
  - 400 `invalid_json` / `missing_refresh_token`
  - 401 `invalid_refresh` — invalid/expired/inactive/reuse_revoked를 **단일 코드로 통합**(토큰 상태 구분 비노출; 상세 사유는 서버 로그만)
  - 429 `rate_limited`
  - 500 `server_misconfigured` / `internal_error`
- **내부 로직**: ① `oldHash = sha256(refresh_token)` ② 레이트리밋 — 토큰해시 `refresh:tok:<hash>` 20/분(스푸핑 불가, grace 증폭 캡) + IP `refresh:ip:<ip>` 120/분(보조) ③ 새 원문 생성 → `rt_rotate(p_old_hash, p_new_hash, p_user_agent, p_grace_seconds=30)` RPC — 원자적 회전(`UPDATE ... WHERE revoked_at IS NULL` 가드) + 30초 grace 유예 ④ 결과 `rotated|grace|recovered`면 `signAccess(user_id, token_version, 8h)` + 새 refresh 반환.
- **시크릿**: `JWT_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 롤링 30일/절대 90일 만료(RPC측), grace 30초(응답 유실 재시도 구제), grace 초과 재사용 = family 전체 회수(탈취 대응).

### logout

- **엔드포인트**: `POST /functions/v1/logout` — verify_jwt=false
- **인증**: refresh 토큰(바디). 유효 access 불요.
- **요청 바디**: `{ refresh_token?: string }` — 잘못된 JSON/빈 토큰도 멱등 성공 처리.
- **응답**: **항상 200 `{ ok: true }`** (토큰 존재 여부 비노출, RPC 오류도 로그만 남기고 200).
- **내부 로직**: 토큰이 있으면 `rt_revoke_family(p_hash=sha256(raw))` RPC — 해당 refresh가 속한 family 전체 회수(현재 기기 로그아웃).
- **시크릿**: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 멱등. 레이트리밋 없음.

### change-password

- **엔드포인트**: `POST /functions/v1/change-password` — verify_jwt=false(커스텀 JWT 수동 검증)
- **인증**: **커스텀 JWT Bearer** (`_shared/auth.ts verifyAccess` — 서명+alg+exp 검증, `sub`→uid, `tv` 클레임 사용). refresh 지원 클라(phase 2) 전용(레거시 직접 RPC `change_password` 는 argon2id 전환 시 드롭).
- **요청 바디**: `{ current_password: string(필수), new_password: string(필수) }`
- **응답**:
  - 200 `{ ok: true, token, refresh_token, expires_in: 28800 }` — 현재 기기용 새 쌍
  - 400 `invalid_json` / `missing_fields` / `weak_password`
  - 401 `unauthorized`(JWT 무효 또는 RPC `not_authenticated` = tv 불일치/정지) / `invalid_current`
  - 500 `server_misconfigured` / `internal_error`
- **내부 로직**: ① JWT 검증 → uid, tv ② 새 refresh 원문 생성 ③ `get_password_hash` 조회 → 엣지에서 현재 비번 검증 → `change_password_and_rotate(p_user, p_current_hash, p_new_hash, p_tv, p_new_token_hash, p_user_agent)` RPC — **단일 트랜잭션**: 세션(status+tv) 검증 → 해시 CAS 갱신(불일치 = invalid_current 롤백) → `token_version` bump + refresh 전량 회수 → 현재 기기용 새 family 발급. 새 tv 반환 ④ 새 tv로 access 서명해 새 쌍 응답.
- **시크릿**: `JWT_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 성공 시 다른 모든 기기 즉시 로그아웃(access는 tv 게이트로 즉사, refresh 회수), 현재 기기만 유지. 레이트리밋 없음(유효 access 필요가 게이트).

### reset-password

- **엔드포인트**: `POST /functions/v1/reset-password` — verify_jwt=false
- **인증**: 없음(로그인 전). 단, `verify-phone-code(purpose='password_reset')`가 **30분 내** 완료된 번호만 허용(RPC에서 검증).
- **요청 바디**: `{ phone: string(필수, /^01\d{8,9}$/ 정규화 후), new_password: string(필수, 8자+영문+숫자) }`
- **응답**:
  - 200 `{ ok: true }`
  - 400 `invalid_json` / `invalid_phone` / `invalid_password`
  - 403 `phone_not_verified`
  - 404 `user_not_found`
  - 500 `internal_error`
- **내부 로직**: 엣지에서 argon2id 해싱 → `reset_password_user(p_phone, p_new_hash)` RPC — 30분 내 인증 이력 확인 → 해시 갱신 + 전 세션 무효화(token_version bump + refresh 회수). CORS/json/normalizePhone을 파일 내 자체 정의.
- **시크릿**: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 인증 유효창 30분. 성공 시 모든 기기 로그아웃.

### verify-location

- **엔드포인트**: `POST /functions/v1/verify-location` — verify_jwt=false(수동 검증)
- **인증**: **커스텀 JWT Bearer** (파일 내 `getUidFromJwt` 복제본 — 서명+exp 검증, `sub`만 사용).
- **요청 바디**: `{ lat: number(필수, 유한값), lng: number(필수), accuracy?: number(반올림, 기본 0), isMocked?: boolean }`
- **응답** (실패도 HTTP 200으로 사유 반환하는 패턴):
  - 200 `{ verified: true, regionCode, regionName, address }`
  - 200 `{ verified: false, reason: "blocked", blockedUntil }` / `{ verified:false, reason:"mock_location" }` / `{ verified:false, reason:"geocode_failed" }`
  - 400 `invalid_json` / `invalid_coords`
  - 401 `unauthorized`, 500 `server_misconfigured` / `internal_error`
- **내부 로직**: ① JWT → uid ② `users.location_verify_blocked_until` 조회 — 미래면 `blocked` ③ `isMocked=true`면 실패 기록 후 거절 ④ **네이버(NCP) Reverse Geocoding** `https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc`(orders=admcode,legalcode,addr) → 행정동 코드(`admcode.code.id`)+시/구/동 라벨(바다 등 행정동 없으면 실패) ⑤ `record_location_verification` RPC(p_result='success'|'failed', p_fail_reason, p_region_code, p_address, p_fail_limit=5, p_block_minutes=60)로 결과 반영 — users의 region_code/is_location_verified/last_verified_at 갱신 및 실패 카운팅.
- **시크릿**: `JWT_SECRET`, `NAVER_MAP_KEY_ID`, `NAVER_MAP_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 연속 실패 5회 → 60분 차단(`location_verify_blocked_until`). 모의위치 거절. 인증 컬럼은 클라 GRANT가 없어 이 함수(service_role) 경로로만 변경 가능.

### verify-post-photo

- **엔드포인트**: `POST /functions/v1/verify-post-photo` — verify_jwt=false(수동 검증)
- **인증**: **커스텀 JWT Bearer**.
- **요청 바디**: `{ imageBase64: string(필수), mimeType?: string(기본 'image/jpeg'), lat: number(필수), lng: number(필수), accuracy?: number, isMocked?: boolean, petId: string(필수) }`
- **응답**:
  - 200 통과 `{ pass: true, token: <검증토큰, TTL 15분>, imageUrl, matchedPetId, species: 'dog'|'cat', matchScore, expiresAt }`
  - 200 실패 `{ pass: false, reason: "not_verified" | "mock_location" | "geocode_failed" | "region_mismatch"(+expected/got) | "pet_not_enrolled" | "ai_unavailable" | "not_real_pet"(+ai) | "identity_mismatch"(+ai) }`
  - 400 `invalid_json` / `missing_image` / `missing_pet` / `invalid_coords`
  - 401 `unauthorized`, 403 `forbidden`(보호자 아님), 500 `server_misconfigured` / `internal_error`
- **내부 로직**: ⓪ `pet_guardians`에서 uid가 petId의 보호자인지 확인 ① `users`의 활동지역 인증 상태 확인 — `is_location_verified`, `last_verified_at`(60일 경과 시 만료 취급), `region_code` ② 모의위치 거절(+`record_photo_verification` 실패 기록) ③ 촬영 좌표를 네이버 역지오코딩 → 행정동 코드가 `users.region_code`와 일치해야 함 ④ `pet_identity_frames`에서 기준 프레임 목록 조회 + Storage `media` 버킷에서 다운로드(없으면 `pet_not_enrolled`) ⑤ **Gemini 2.5 Pro**(구조화 JSON 출력, temperature 0, 429 시 최대 2회 backoff 재시도)로 기준 프레임 N장 + 게시 사진 1장 → 동일 개체 `identity_score` + 라이브니스(`is_real`, dog/cat_real/fake) 판정 ⑥ `is_real && real>fake`(라이브니스) AND `identity_score >= 0.63`(동일 개체) 통과 시 → 사진을 `media/<uid>/posts/<ts>.jpg`로 업로드 → `record_photo_verification` RPC(p_result='pass', p_ttl_min=15, p_pet_id, p_match_score, p_matched=true 등)가 **검증 토큰** 반환(게시글 작성 시 제출). 실패 경로 중 `mock_location`/`geocode_failed`/`region_mismatch`/`not_real_pet`/`identity_mismatch`는 RPC로 실패 기록을 남기지만, `not_verified`/`pet_not_enrolled`/`ai_unavailable`은 기록 없이 반환한다.
- **시크릿**: `JWT_SECRET`, `NAVER_MAP_KEY_ID`, `NAVER_MAP_KEY`, `GEMINI_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 지역 재인증 주기 60일(`REVERIFY_DAYS`), 검증 토큰 TTL 15분, 라이브니스 하한 0.70(상수 `AI_REAL_THRESHOLD` — 실제 판정은 `is_real && real>fake` 사용), 동일 개체 통과선 0.63.

### enroll-pet-identity

- **엔드포인트**: `POST /functions/v1/enroll-pet-identity` — verify_jwt=false(수동 검증)
- **인증**: **커스텀 JWT Bearer**.
- **요청 바디**: `{ petId: string(필수), challenge: string[](필수, 1개 이상. 알려진 코드: pat_head|hold_paw|scratch_chin|stroke_back|hand_in_frame — 단 서버는 목록을 강제하지 않으며 미지 코드는 문자열 그대로 Gemini 프롬프트에 들어감), videoBase64: string(필수), videoMime?: string(기본 'video/mp4'), frames: string[](필수, base64 3장 이상), mimeType?: string(기본 'image/jpeg') }`
- **응답**:
  - 200 성공 `{ enrolled: true, species, breed, colors, frameCount, frames: [url...], infoMatch: { species_kind, breed, color, warnings }, warnings, challengePassed: true }`
  - 400 `{ enrolled: false, reason: "missing_pet" | "no_video" | "too_few_frames" | "no_challenge" }` / `invalid_json`
  - 200 실패 `{ enrolled: false, reason: "ai_unavailable"(+detail/videoKb 진단) | "not_real_pet"(+ai) | "not_consistent_pet"(+ai) | "challenge_failed"(+missing, ai) }`
  - 401 `unauthorized`, 403 `{ enrolled:false, reason:"not_guardian" }`, 500 `server_misconfigured` / `internal_error`
- **내부 로직**: ① `pet_guardians` 보호자 확인 ② `pets`에서 등록 종(`species_kind`)/품종(`species`)을 **서버가 직접 읽음**(클라 입력 불신) ③ **Gemini 2.5 Pro 영상 판별**(구조화 출력): 실제 살아있는 개/고양이 여부(dog/cat_real/fake ≥ 0.70 & real>fake), 영상 내내 동일 개체(`consistent`), 지시된 무작위 임무(challenge) 수행 여부(`challenges_done`), 추정 품종/털색 ④ 등록정보 교차검증 — 종/품종 불일치는 **소프트 경고**(통과에 영향 없음, `looseBreedMatch` 느슨 비교: 소문자·공백 제거 후 부분 포함, 믹스는 관대) ⑤ 통과 시 **프레임 N장만** `media/<uid>/pet_identity/<petId>/<i>.jpg`로 업로드(upsert) + `enroll_pet_identity` RPC(p_pet, p_species, p_breed, p_colors, p_info_match, p_paths, p_urls). **★ 영상은 저장하지 않음**(Gemini 인라인 전송 후 메모리에서 소멸 — Storage/DB 미기록).
- **시크릿**: `JWT_SECRET`, `GEMINI_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 라이브니스 하한 0.70(`ENROLL_REAL_THRESHOLD`), 프레임 최소 3장, 임무 최소 1개(전부 수행돼야 통과). Gemini 429 시 1.5s/3s backoff 최대 2회 재시도.

### search-petcafe

- **엔드포인트**: `POST /functions/v1/search-petcafe` — verify_jwt=false(수동 검증)
- **인증**: **커스텀 JWT Bearer**.
- **요청 바디**: `{ lat?: number, lng?: number, query?: string }` — `query` 있으면 이름 검색(위치 무관), 없으면 좌표를 역지오코딩해 `"<시군구 읍면동> 애견카페"`로 지역 한정 검색.
- **응답**:
  - 200 `{ items: [{ category: "pet_cafe", name, address, phone, lat, lng }] }` (최대 5건)
  - 200 `{ items: [], error: "naver_unreachable" | "naver_<status>" }` — 네이버 API 실패도 200으로 빈 목록
  - 400 `invalid_json`, 401 `unauthorized`, 500 `server_misconfigured`
- **내부 로직**: ① JWT → uid ② (query 없으면) NCP 역지오코딩으로 지역명 획득 ③ **네이버 지역검색 API** `https://openapi.naver.com/v1/search/local.json?query=...&display=5&sort=comment`(키는 서버 시크릿 — 앱 비노출) ④ 결과 필터: 분류(category)에 애견/애완/반려/펫 또는 '카페' 포함만 통과(화이트리스트 — 무관 업소 오라벨링 방지), HTML 태그 제거, `mapx/mapy`(위경도×1e7 정수) → WGS84 환산 + 한국 bbox(경도 124~132, 위도 33~39) 검사.
- **시크릿**: `JWT_SECRET`, `NAVER_CLIENT_ID`, `NAVER_CLIENT_SECRET`(지역검색), `NAVER_MAP_KEY_ID`, `NAVER_MAP_KEY`(역지오코딩), (`ALLOW_ORIGIN`)
- **정책**: display 5건 한계(네이버 지역검색). DB 접근 없음(순수 프록시).

### resolve-region

- **엔드포인트**: `POST /functions/v1/resolve-region` — verify_jwt=false(수동 검증)
- **인증**: **커스텀 JWT Bearer**.
- **요청 바디**: `{ lat: number(필수, 유한값), lng: number(필수) }`
- **응답**:
  - 200 `{ regionCode, regionName, address }` — 실패(바다 등) 시 `{ regionCode: null, regionName: null, address: null }` (역시 200)
  - 400 `invalid_json` / `invalid_coords`, 401 `unauthorized`, 500 `server_misconfigured`
- **내부 로직**: NCP 역지오코딩(admcode)만 수행. **DB 변경/인증 기록 없음**(부수효과 없음) — 게시글 작성 시 "현재 위치가 인증 동네와 다른지" 안내용.
- **시크릿**: `JWT_SECRET`, `NAVER_MAP_KEY_ID`, `NAVER_MAP_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 없음(조회 전용).

### sync-dong-centroids

- **엔드포인트**: `POST /functions/v1/sync-dong-centroids` — verify_jwt=false(수동 검증)
- **인증**: **커스텀 JWT Bearer** (로그인 사용자면 누구나 — 멱등 배치라 무해하다는 설계).
- **요청 바디**: `{}` (빈 객체; 바디 파싱 없음)
- **응답**: 200 `{ added: <upsert 건수> }` / 401 `unauthorized` / 500 `server_misconfigured` / `{ error: "seeds_failed", detail }`(500)
- **내부 로직**: ① `dong_centroid_seeds` RPC — centroid 미보유 행정동의 seed 좌표 목록 ② 각 seed에 대해 NCP **역**지오코딩으로 "시 구 동" 이름 획득 → 그 이름으로 NCP **정**지오코딩(`map-geocode/v2/geocode`)해 동 대표좌표 획득(실패 시 seed 좌표 폴백) ③ `dong_centroids` 테이블에 upsert(`source: 'geocode'|'seed'`).
- **시크릿**: `JWT_SECRET`, `NAVER_MAP_KEY_ID`, `NAVER_MAP_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`)
- **정책**: 멱등(이미 centroid 있는 동은 seed 대상이 아님). 레이트리밋 없음.

### send-push

- **엔드포인트**: `POST /functions/v1/send-push` — verify_jwt=false
- **인증**: **공유 시크릿 헤더** `x-push-secret == PUSH_TRIGGER_SECRET`(DB 트리거/pg_cron과 공유). 사용자 JWT 아님. 불일치 시 401 `unauthorized`, 미설정 시 503 `not_configured`.
- **호출자**: `notifications` 테이블 트리거(단건, `notification_id` 지정) + pg_cron 스윕(배치, 빈 바디).
- **요청 바디**: `{ notification_id?: string }` — 없거나 JSON 파싱 실패 시 배치 모드(최대 100건).
- **응답**:
  - 200 `{ ok: true, processed: n }` / `{ ok: true, sent: 0 }`(대상 없음) / `{ ok: true, skipped: "fcm_not_configured" }`(FCM 미설정 — pending 유지)
  - 401 `unauthorized`, 405, 500 `bad_service_account` / `dispatch_failed`, 502 `oauth_failed` (이때 이미 claim한 알림들은 `push_report`로 전부 `ok:false, error:"oauth_failed"` 실패 보고됨 — pending으로 남지 않음), 503 `not_configured`
- **내부 로직**: ① `push_dispatch_batch(p_only_id, p_limit=100)` RPC로 pending 알림+대상 디바이스 토큰 클레임 ② `FCM_SERVICE_ACCOUNT`(Google 서비스계정 JSON)의 private_key로 RS256 JWT 서명 → Google OAuth2 토큰 교환(`firebase.messaging` scope, 함수 인스턴스 내 캐시) ③ 각 알림×토큰마다 **FCM HTTP v1** `projects/<id>/messages:send` 호출 — `notification`(제목/본문; 앱 종료 상태에서도 OS 표시) + `data`(type/notification_id/resource_type/resource_id — 탭 라우팅), android priority high / apns-priority 10 ④ `UNREGISTERED`/`INVALID_ARGUMENT`/404 응답 토큰은 dead 처리 ⑤ `push_report(p_results)` RPC로 sent/failed 반영 + 죽은 토큰 비활성화.
- **시크릿**: `PUSH_TRIGGER_SECRET`, `FCM_SERVICE_ACCOUNT`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, (`ALLOW_ORIGIN`). CORS 헤더에 `x-push-secret` 추가 허용(자체 정의).
- **정책**: 배치 100건 제한. OAuth 토큰 캐시(만료 60초 전 갱신). FCM 미설정 시 pending 유지 후 skip.

## 5. 시크릿/환경변수 목록

| 변수 | 사용 함수 | 용도 |
|---|---|---|
| `SUPABASE_URL` | 전 함수(DB 접근하는 모든 함수) | 플랫폼 자동 주입 |
| `SUPABASE_SERVICE_ROLE_KEY` | 전 함수(DB 접근) | 플랫폼 자동 주입. service_role 클라이언트 생성 |
| `JWT_SECRET` | login, refresh, change-password, verify-location, verify-post-photo, enroll-pet-identity, search-petcafe, resolve-region, sync-dong-centroids | Supabase 프로젝트 JWT Secret — access JWT 서명/검증 |
| `ALLOW_ORIGIN` | 전 함수(CORS) | 미설정 시 `*`. 운영 시 오리진 제한 가능 |
| `SOLAPI_API_KEY` / `SOLAPI_API_SECRET` / `SOLAPI_SENDER` | send-phone-code | Solapi SMS (SENDER는 콘솔 사전등록 발신번호) |
| `NAVER_MAP_KEY_ID` / `NAVER_MAP_KEY` | verify-location, verify-post-photo, search-petcafe, resolve-region, sync-dong-centroids | NCP Maps Reverse/Forward Geocoding (Client ID/Secret) |
| `NAVER_CLIENT_ID` / `NAVER_CLIENT_SECRET` | search-petcafe | 네이버 오픈API 지역검색 |
| `GEMINI_API_KEY` | verify-post-photo, enroll-pet-identity | Google Gemini 2.5 Pro (유료 등급/billing) |
| `PUSH_TRIGGER_SECRET` | send-push | DB 트리거/pg_cron과 공유하는 호출 인증 시크릿 |
| `FCM_SERVICE_ACCOUNT` | send-push | Google 서비스계정 JSON (FCM HTTP v1 OAuth) |

`.env.example`(`supabase/functions/.env.example`)에는 `GEMINI_API_KEY_ID`도 있으나 코드에서 미사용. 시크릿 등록은 `supabase secrets set --env-file supabase/functions/.env --project-ref vyatppuxmpulqtxevfpk`.

## 6. 배포 현황 및 로컬-원격 차이

배포 함수(2026-07-02 기준, `list_edge_functions`): 15개 전부 ACTIVE. 로컬 소스 15개와 **슬러그 기준 1:1 일치** — 원격에만 있거나 로컬에만 있는 함수 없음.

| 슬러그 | 버전 | verify_jwt | 비고 |
|---|---|---|---|
| send-phone-code | v12 | **true** | config.toml로 고정 (남용 게이트) |
| verify-phone-code | v12 | **true** | config.toml로 고정 (남용 게이트) |
| signup | v10 | **true** | config.toml로 고정 (남용 게이트) |
| login | v18 | false | |
| verify-location | v10 | false | |
| verify-post-photo | v9 | false | |
| enroll-pet-identity | v8 | false | |
| search-petcafe | v9 | false | |
| sync-dong-centroids | v3 | false | |
| resolve-region | v3 | false | |
| refresh | v6 | false | |
| logout | v3 | false | |
| change-password | v6 | false | |
| reset-password | v3 | false | |
| send-push | v3 | false | |

주요 드리프트/특이사항:

1. **verify_jwt 드리프트 → 해결됨 (2026-07-02, `supabase/config.toml` 추가)**: 과거에는 config.toml이 없어 재배포 시 `--no-verify-jwt` 수동 관례에 의존했고, 실제로 send-phone-code / verify-phone-code / signup 3개가 원격에서 verify_jwt=**true**로 리셋되는 드리프트가 있었다(소스 주석/README 의도는 false). 현재는 `supabase/config.toml`이 함수별 verify_jwt를 명시해 `supabase functions deploy`가 결정론적으로 적용한다 — 값은 운영 원격 상태와 동일하게 고정(동작 변화 없음). 최종 정책: 전화인증/가입 3개는 **의도적으로 true**(publishable 키 요구를 얇은 남용 게이트로 유지 — 게이트웨이가 유효 JWT[legacy anon key 포함]를 Bearer로 요구; JWT 형식이 아닌 새 `sb_publishable_...` 키만 쓰는 클라이언트로 전환하려면 false + 내부 레이트리밋 의존으로 변경 필요), 나머지 12개는 false(커스텀 JWT 수동 검증; 특히 send-push는 pg_net이 apikey 없이 `x-push-secret`만으로 호출하므로 반드시 false). 잔여 정리 대상: 세 함수의 소스 헤더 주석은 아직 "verify_jwt=false"라고 적혀 있어 config.toml/배포 상태(true)와 어긋난다 — 주석 갱신 필요.
2. **배포 루트 불일치(entrypoint 경로)**: login/refresh/logout/change-password/reset-password/send-push/search-petcafe는 `source/functions/<slug>/index.ts`, 나머지는 `source/supabase/functions/<slug>/index.ts`로 기록돼 있다 — 배포 시 실행 위치(리포 루트 vs `supabase/` 디렉터리)가 달랐던 흔적. 동작에는 영향 없음.
3. **README 문서 지연**: `/Users/seize_h/StudioProjects/pmdb/README.md`의 Edge Functions 표는 초기 4개(send-phone-code, verify-phone-code, signup, login)만 기재 — 이후 추가된 11개 함수와 시크릿(NAVER_*, GEMINI_API_KEY, PUSH_TRIGGER_SECRET, FCM_SERVICE_ACCOUNT 등)이 누락돼 있다.
4. **JWT 검증 로직 중복**: `_shared/auth.ts`의 `verifyAccess`(alg 고정 확인 포함)와 별개로 6개 함수(verify-location, verify-post-photo, enroll-pet-identity, search-petcafe, resolve-region, sync-dong-centroids)가 자체 `getUidFromJwt`(alg 확인 없음)를 복제해 유지한다 — 통합 여지.
5. `supabase/functions/supabase/` 와 `verify-phone-code/supabase/` 는 CLI `.temp` 아티팩트(linked-project.json, ref=vyatppuxmpulqtxevfpk)로 함수가 아니며 배포 대상도 아니다.
6. `supabase/queries/`에는 `pet_sales_chain_candidates.sql`(펫샵 후보 조회용 ad-hoc SQL) 1건만 있고 엣지 함수와 무관하다.
7. 설계 문서 §11의 "후속(미구현)" 중 change-password 비원자성은 이후 `change_password_and_rotate` 단일 트랜잭션 RPC로 해소됨(현행 소스 기준). `pg_cron` 정리잡(refresh_tokens/rate_limits), `logout_all` UI 등은 규모 진입 신호 시 도입 예정.
