# Refresh-Token + Session-Version 설계 (v1 "thin full")

> 상태: 설계(미구현). 작성 2026-07-01, 개정 2026-07-01(리뷰 반영). 관련 이슈 #23(MEDIUM #3 후속).
> 현행: 무상태 HS256 access JWT 1개(exp 30일), 서버측 무효화/유출대응 없음.
> 정지/차단·삭제는 이미 `app.uid()` status 게이트로 매 요청 즉시 차단됨(`20260630180000`).

## 0. 범위 결정 ("thin full")

**원칙**: 되돌리기 어려운 건 **클라이언트 토큰 계약**(access+refresh 구조, secure storage, 갱신 훅)이다. 설치 베이스가 커진 뒤 retrofit하면 아프다 → **사용자 적은 지금 앞당겨 박는다**. 반대로 서버에서 무앱변경으로 언제든 조일 수 있는 건 **access 수명 하나뿐** → **보수적으로 시작(6~12h)** 하고 신뢰 쌓이면 서버-only로 단축. `token_version`(즉시 무효화)은 거의 공짜라 **무조건 포함**.

**v1 본체에 포함:**
- `app.refresh_tokens` 테이블 (+ `replaced_by` FK `on delete set null`)
- `users.token_version`(세션 epoch) + `app.uid()`에 tv 비교 추가 — 즉시 전역 무효화
- `login` 수정(클라 capability 감지 → access[6~12h, tv 클레임] + refresh)
- `refresh`(**원자적 회전 + grace 유예** — 타협 불가, 빠지면 랜덤 로그아웃)
- `logout`(family 회수)
- 정지/차단·비번변경 시 회수 연동
- 앱 `accessToken` 콜백 단일비행 갱신 훅 + secure storage
- **기본 레이트리밋**(login/refresh)
- access 수명 **6~12h로 시작**(추후 서버-only로 1h)

**v1에서 제외(규모 기능 — 10만 진입 신호 시 추가):**
- `pg_cron` 정리잡(만료/회수 토큰 삭제)
- `logout_all` 제품 UI
- 사용자당 refresh 토큰 cap·prune
- 지터/세밀 레이트리밋 튜닝

## 1. 토큰 모델

| | 형식 | 수명 | 클라 저장 | 서버 저장 | 무효화 수단 |
|---|---|---|---|---|---|
| access  | HS256 JWT (현행, `JWT_SECRET` 서명, `sub/role/aud/iss` **+ `tv`**) | **6~12h 시작** → 추후 1h | secure storage | 없음(무상태) | `token_version` bump(즉시) / 만료 |
| refresh | 불투명 랜덤 256bit | 롤링 30일 / 절대 90일 | secure storage | **SHA-256 해시만** | 회수(회전/로그아웃/정지) |
| session-version | `users.token_version` int | — | (access `tv` 클레임) | — | bump = 전체 access 즉사 |

- access는 PostgREST 네이티브 검증 유지. 추가로 `tv` 클레임을 `app.uid()`가 검사.
- access/refresh **둘 다 secure storage**(현행 SharedPreferences→`flutter_secure_storage`, 일관성).

## 2. DB

```sql
-- 세션 epoch: bump 시 그 사용자의 모든 access 즉시 무효(매 요청 app.uid 가 비교).
alter table public.users add column token_version integer not null default 0;

create table app.refresh_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  token_hash  text not null unique,            -- sha256(원문 refresh)
  family_id   uuid not null,                   -- 회전 패밀리(탈취 탐지)
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,            -- 롤링(회전마다 now()+30d)
  absolute_expires_at timestamptz not null,    -- family 최초 발급+90일(불변)
  revoked_at  timestamptz,
  replaced_by uuid references app.refresh_tokens(id) on delete set null, -- 정리잡 FK위반 방지
  user_agent  text
);
create index refresh_tokens_user_idx   on app.refresh_tokens(user_id);
create index refresh_tokens_family_idx on app.refresh_tokens(family_id);

alter table app.refresh_tokens enable row level security;
-- 정책 0개 + anon/authenticated GRANT 없음 → service_role(엣지)만 접근.
```

## 3. `app.uid()` 확장 — token_version 즉시 무효화

status 게이트가 이미 매 요청 users 행을 읽으므로 **컬럼 1개 비교만 추가**(비용 ≈ 0). JWT의 `tv` 클레임 ≠ `users.token_version` 이면 로그아웃 처리(NULL 반환). **클레임 없음 = 0 취급**(레거시 30일 토큰 하위호환; `token_version` 기본 0이라 일치).

```sql
create or replace function app.uid()
returns uuid language sql stable security definer set search_path to ''
as $$
  select u.id
  from public.users u
  where u.id = nullif((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'sub','')::uuid
    and u.status = 'active'
    and u.token_version = coalesce(
      ((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'tv')::int, 0)
$$;
```
→ `token_version`++ 하면 그 사용자의 모든 access 가 **access 수명과 무관하게 즉시** 무효. 그래서 access를 6~12h로 길게 시작해도 비상 차단(탈취·전체 로그아웃)은 안 늦는다.

## 4. Edge Functions

공통: refresh 원문 = `crypto.getRandomValues(32바이트)`→base64url. 서버는 `sha256` 해시만 저장/조회. **login/refresh 기본 레이트리밋**(반복 401 잠금 포함).

### `login` (수정)
1. `login_user`로 비번 검증(이미 `status='active'`만).
2. **클라 capability 감지**(요청 헤더/필드 예: `x-client-refresh: 1` 또는 앱 버전):
   - 지원 → access(exp 6~12h, `tv = users.token_version` 클레임 포함) + refresh 발급(새 family, `expires_at=now()+30d`, `absolute_expires_at=now()+90d`).
   - 미지원(레거시 앱) → 기존 30일 access만, **단 `tv = users.token_version` 클레임은 항상 포함**(점진 제거 대상).
3. 응답 `{ access_token, refresh_token?, expires_in, user }`.

> ⚠️ **새로 찍는 모든 토큰(레거시 분기 포함)에 반드시 현재 `tv` 를 stamp**. §3의 "클레임 없음=0"은 *이미 발급된 과거 토큰* 구제용일 뿐이다. tv 가 한 번이라도 bump된 사용자(예: 비번변경으로 1)가 tv 없는 새 토큰을 받으면 `0 ≠ 1` 로 **로그인하자마자 전 요청 무효(즉시 잠김)** 된다.

### `refresh` (신규, verify_jwt=false) — **원자적 회전 + grace (핵심)**
`POST { refresh_token }`
```
h = sha256(refresh_token)
row = SELECT * FROM app.refresh_tokens WHERE token_hash = h
if not row:                       return 401            -- 미상 토큰
if user.status != 'active':       revoke_family(row.family_id); return 401
if now > row.absolute_expires_at or now > row.expires_at: return 401  -- 만료 → 재로그인

if row.revoked_at IS NULL:
    -- 정상 경로: 원자적 회전(경쟁 방지)
    new = INSERT (same family_id, expires=now()+30d, absolute=row.absolute_expires_at)
    affected = UPDATE app.refresh_tokens
               SET revoked_at=now(), replaced_by=new.id
               WHERE id=row.id AND revoked_at IS NULL          -- 동시 회전 가드
               RETURNING id
    if affected == 0:             -- 그 사이 다른 요청이 이미 회전 → grace 로 처리
        delete new; goto GRACE
    return { access(tv 포함), refresh=new.raw, expires_in }

else:   -- 이미 revoked = 재시도(응답 유실) 또는 탈취
  GRACE:
    if now - row.revoked_at <= GRACE_WINDOW (30s):
        -- 모바일 응답 유실 재시도로 간주: family 회수 금지.
        -- 같은 family 로 새 토큰 1개 발급(이전 orphan 은 무해, 만료/정리로 소멸).
        new = INSERT (same family_id, expires=now()+30d, absolute=row.absolute_expires_at)
        return { access(tv 포함), refresh=new.raw, expires_in }
    else:
        revoke_family(row.family_id); return 401            -- grace 초과 재사용 = 진짜 탈취
```
> **이 grace 유예가 없으면**: 클라가 회전 응답을 네트워크에서 잃고 old 토큰으로 재시도 → 서버가 "탈취"로 family 회수 → **정상 사용자 강제 로그아웃**(모바일에서 흔함). 타협 불가.

### `logout` (신규)
`POST { refresh_token }` → 그 토큰의 **family 회수**. 멱등.

## 5. 정지/차단·비번변경 연동
- **정지/차단**(`admin_set_user_status`→비active): access는 `app.uid` 게이트로 즉시 차단. 추가로 그 user **refresh 전체 회수**(재발급 차단). (원하면 `token_version`++ 로 access도 즉발 무효 — status 게이트가 이미 잡지만 이중.)
- **`change_password`** 성공:
  - `token_version`++ → **모든 기존 access 즉시 무효**(타 기기 즉사).
  - **타 기기 refresh 회수**, 단 **현재 기기엔 응답으로 새 access+refresh 재발급**(현재 기기 로그아웃 방지 — UX 표준).
  - ⚠️ **의존성**: 현재 기기 재발급은 refresh 원문 생성 + JWT 서명이 필요 → **`change_password` 가 엣지 함수 경로여야 한다**. 현재는 PLpgSQL RPC(`change_password(p_current,p_new)`)라, 엣지로 감싸 *비번검증(RPC 재사용) → token_version++ → 토큰 발급* 순으로 처리(롤아웃 1단계에 포함).
- **삭제**: `on delete cascade` 로 토큰 자동 제거.

## 6. 앱(pmdart) 통합 — 기존 `accessToken` 콜백을 갱신 훅으로
`main.dart`의 `accessToken: () async => SessionManager.token` 확장(인터셉터 불필요):
```dart
accessToken: () async {
  final s = SessionManager.instance;
  if (s.refresh != null && s.isAccessExpiringSoon(skew: 60)) { // exp 디코드(무네트워크)
    await s.refreshOnce();      // 단일비행(mutex): 동시 요청 1회만 갱신
  }
  return s.access;
}
```
- `refreshOnce()`: `refresh` 호출 → 새 쌍 저장. **실패(401) → 세션 clear → 로그인 화면**.
- 저장: `SessionManager`에 `access`/`refresh` 분리, **둘 다 `flutter_secure_storage`**.
- 로그아웃: `logout` 호출 + 저장소 clear.
- 로그인 요청에 capability 플래그(`x-client-refresh: 1`) 첨부.

## 7. 롤아웃 (클라 채택이 게이트)
1. **백엔드 배포**: `users.token_version` + `app.uid` 갱신 + `app.refresh_tokens` + `refresh`/`logout` + `login` capability 분기. 레거시 앱은 계속 30일 access(무중단).
2. **앱 v1 출시**: capability 플래그 + refresh 저장/갱신 훅. 신규/업데이트 사용자부터 access 6~12h + refresh.
3. **(추후, 서버-only)** 레거시 앱 비중 충분히 감소 후 access 수명을 1h로 단축 + 레거시 30일 분기 제거.

→ capability 감지로 무중단 전환. 되돌리기 어려운 클라 변경은 1~2단계에서 끝나고, 마지막 조이기는 서버만.

## 8. 보류(규모) 항목 + 도입 신호
| 항목 | 도입 신호 |
|---|---|
| `pg_cron` 정리잡(만료/회수 토큰 삭제) | **느슨한 상한: `refresh_tokens` 행 > 10만**(또는 테이블 수십 MB). grace 재발급·미로그아웃으로 행이 단조증가하므로 이 상한 돌파 전 도입 |
| 사용자당 refresh cap·prune | **사용자당 활성 family > ~10**, 또는 위 정리잡과 함께 |
| `logout_all` 제품 UI | "다른 기기 로그아웃" 기능 요구 |
| 지터·세밀 레이트리밋 | refresh QPS 피크(≈10만 사용자) |
| access 1h 단축 | 유출 우려↑ 또는 신뢰 확보 후(서버-only) |

> `logout_all`·민감작업은 **유효 access(app.uid) 필수**로 게이트(불투명 refresh 소지만으로 호출 불가).

## 9. access 수명 ↔ 규모 트레이드오프 (참고)
refresh 호출량 ≈ `활성 사용자 × (활동시간 ÷ access수명)`. token_version 이 비상 차단을 즉발로 보장하므로 **access는 길게 시작해도 안전** → 6~12h로 출발해 트래픽·회전경쟁 최소화, 추후 서버-only 단축.

| 규모 | access 1h | access 6~12h(시작) | access 24h |
|---|---|---|---|
| 1만 명  | ~3만 갱신/일 무시가능 | ~3~6천/일 | ~1만/일 |
| 10만 명 | ~30만/일(≈3.5/s) | ~3~6만/일 | ~10만/일 |

## 10. 보안 체크리스트
- [ ] refresh 원문 미저장(해시만), 로깅 금지
- [ ] **원자적 회전**(`UPDATE ... WHERE revoked_at IS NULL RETURNING`) + **grace 유예(30s)** — 빠지면 랜덤 로그아웃
- [ ] grace 초과 재사용만 family 회수(진짜 탈취)
- [ ] `users.token_version` ↔ access `tv` 클레임 비교(즉시 전역 무효화), 클레임 없음=0 하위호환
- [ ] **새로 발급하는 모든 토큰(레거시 분기 포함)에 현재 `tv` stamp** — "클레임 없음=0"은 과거 토큰 구제용일 뿐(미stamp 시 bump된 사용자 재로그인 즉시 잠김)
- [ ] **`change_password` 는 엣지 경로**(현기기 토큰 재발급에 JWT 서명 필요 — 현행 RPC를 엣지로 감쌈)
- [ ] 정지/차단·비번변경 시 회수 연동(비번변경=타기기 회수+현기기 재발급)
- [ ] `logout_all`·민감작업은 유효 access 필수(refresh 단독 불가)
- [ ] `refresh`/`login` 기본 레이트리밋(반복 401 잠금)
- [ ] `replaced_by` FK `on delete set null`(정리잡 FK위반 방지)
- [ ] 앱: access+refresh 모두 secure storage, 단일비행 갱신, 401→강제 로그아웃
- [ ] 롤아웃: capability 감지로 무중단, access 6~12h 시작→서버-only 1h 단축
