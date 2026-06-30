# Refresh-Token 흐름 설계 (PawMate 커스텀 인증)

> 상태: 설계(미구현). 작성 2026-07-01. 관련 이슈 #23(MEDIUM #3 후속).
> 현행: 무상태 HS256 access JWT 1개(exp 30일), 서버측 무효화/유출대응 없음.
> 정지/차단·삭제는 이미 `app.uid()` status 게이트로 즉시 차단됨(`20260630180000`).
> 본 설계는 남은 위험 — **활성 사용자의 access 토큰 유출 시나리오** — 를 닫는다.

## 1. 토큰 모델

| | 형식 | 수명(권장) | 클라 저장 | 서버 저장 | 검증 |
|---|---|---|---|---|---|
| access  | HS256 JWT (현행 유지, `JWT_SECRET` 서명, `sub/role/aud/iss`) | **1시간**(규모별 조정 §7) | secure storage | 없음(무상태) | PostgREST 네이티브 + `app.uid` 상태게이트 |
| refresh | 불투명 랜덤 256bit (JWT 아님) | **롤링 30일 / 절대 90일** | `flutter_secure_storage` | **SHA-256 해시만** | DB 조회 |

- access는 현행 그대로 PostgREST가 네이티브 검증 → RLS(`app.uid`) 무변경.
- refresh는 JWT가 아닌 불투명 토큰: 서버가 회수/만료 상태를 DB로 관리해야 하므로. 원문 저장 금지, 해시만.

## 2. DB — `refresh_tokens`

```sql
create table app.refresh_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  token_hash  text not null unique,          -- sha256(원문 refresh)
  family_id   uuid not null,                 -- 회전 패밀리(탈취 탐지)
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,          -- 롤링 갱신, 절대상한 별도 체크
  absolute_expires_at timestamptz not null,  -- family 최초 발급 + 90일(불변)
  revoked_at  timestamptz,
  replaced_by uuid references app.refresh_tokens(id),
  user_agent  text
);
create index refresh_tokens_user_idx   on app.refresh_tokens(user_id);
create index refresh_tokens_family_idx on app.refresh_tokens(family_id);

alter table app.refresh_tokens enable row level security;
-- 정책 0개 + anon/authenticated GRANT 없음 → service_role(엣지)만 접근(최소권한).
```

> `app` 스키마에 둔다(PostREST 비노출, RPC/엣지 전용). RLS 정책 없음 = 외부 직접접근 차단.

## 3. Edge Functions (pmdb/supabase/functions)

공통: refresh 원문은 `crypto.getRandomValues(32바이트)` → base64url. 서버는 `sha256` 해시만 저장/조회.

### `login` (수정)
1. 기존대로 `login_user`로 비번 검증(이미 `status='active'`만 통과).
2. access JWT 발급(exp = §7 값).
3. refresh 원문 생성 → `refresh_tokens`에 `family_id=새 uuid`, `expires_at=now()+30d`, `absolute_expires_at=now()+90d`로 INSERT.
4. 응답 `{ access_token, refresh_token, expires_in, user }`.

### `refresh` (신규, verify_jwt=false)
`POST { refresh_token }`
1. `sha256(refresh_token)`로 행 조회 → 없으면 `401`.
2. **재사용 탐지**: 행이 이미 `revoked_at` 있음(=회전으로 교체됐는데 또 제시됨) → 탈취로 간주, **그 family 전체 회수** + `401`.
3. `expires_at < now()` 또는 `absolute_expires_at < now()` → `401`(만료, 재로그인).
4. `users.status != 'active'` → `401` + 그 user refresh 전체 회수.
5. **회전(rotation)**:
   - 기존 행 `revoked_at=now()`, `replaced_by=<새 행 id>`.
   - 같은 `family_id`로 새 refresh INSERT, `expires_at=now()+30d`(롤링), `absolute_expires_at`는 **승계(불변)**.
   - 새 access JWT 발급.
6. 응답 `{ access_token, refresh_token, expires_in }`.

### `logout` (신규)
`POST { refresh_token }` → 해당 토큰(권장: family 전체) 회수. 멱등.

### `logout_all` (선택)
사용자 전체 family 회수(여러 기기 강제 로그아웃).

## 4. 정지/차단·비번변경 연동
- **정지/차단**(`admin_set_user_status`→비active): access는 `app.uid` 게이트로 즉시 차단. 추가로 **해당 user refresh 전체 회수**(RPC 내부 또는 status 변경 트리거)로 재발급 차단 → access 만료(≤1h) 후 완전 로그아웃.
- **`change_password`** 성공 시: 본인 refresh 전체 회수(타 기기 강제 로그아웃, 표준).
- 삭제: `on delete cascade`로 토큰 자동 제거.

## 5. 앱(pmdart) 통합 — 기존 `accessToken` 콜백을 갱신 훅으로

현재 `main.dart`의 `accessToken: () async => SessionManager.token`가 매 요청마다 호출됨 → 여기서 중앙 갱신(인터셉터 불필요):

```dart
accessToken: () async {
  final s = SessionManager.instance;
  if (s.refresh != null && s.isAccessExpiringSoon(skew: 60)) { // exp 디코드로 판단(무네트워크)
    await s.refreshOnce(); // 단일비행(mutex): 동시 요청이 한 번만 갱신
  }
  return s.access;
}
```
- `refreshOnce()`: refresh 엔드포인트 호출 → 새 쌍 저장. **실패(401) → 세션 clear → 로그인 화면**.
- **단일비행**: 진행 중 Future 공유로 동시 갱신 방지.
- **지터**: 만료 임박 판단에 ±랜덤 skew → 동시 폭주(thundering herd) 완화(대규모 §7).
- 저장: `SessionManager`에 `access`/`refresh` 분리. refresh는 `flutter_secure_storage`(현 access는 SharedPreferences — refresh는 더 민감).
- 로그아웃: `logout` 호출 + 저장소 clear.

## 6. 롤아웃 단계 (하위호환 — 중요)
access exp를 줄이면, **구버전 앱(갱신 미지원)은 기존 토큰 만료 후 로그아웃**된다. 순서:
1. **DB 테이블 + `refresh`/`logout` 함수 배포**. `login`은 refresh도 반환하되 **access exp는 30일 유지**.
2. **앱 갱신 지원 출시**(refresh 저장/사용, accessToken 훅).
3. 보급 충분 후 **`login` access exp를 1h로 단축** → 이때부터 유출창 축소 효과.

→ 무중단 전환, 구버전은 자연 만료/업데이트로 흡수.

## 7. access 수명 ↔ 규모 트레이드오프
refresh 호출량 ≈ `활성 사용자 × (활동시간 ÷ access수명)`. 짧을수록 보안↑·갱신호출/비용↑. 정지·차단은 `app.uid` 게이트로 즉시 처리되므로 access 수명이 좌우하는 건 **유출된 활성 토큰의 유효창**뿐.

추정(활성자 하루 ~3h 사용, 갱신 1회=엣지호출1+DB 2~3):

| 규모 | access 15분 | access 1시간 | access 24시간 |
|---|---|---|---|
| 1만 명  | ~12만/일(≈1.4/s) 무시가능 | ~3만/일 무시가능 | ~1만/일 |
| 10만 명 | ~120만/일(≈14/s, 피크~100/s) + 토큰행 폭증→정리잡 필수 | ~30만/일(≈3.5/s) 양호 | ~10만/일 최소지만 유출창 24h |

권장:
- **1만 명**: 부하 ~0 → 보안 기준 선택(15분~1시간 무난). 기본 **1시간**.
- **10만 명+**: access 수명이 refresh QPS·엣지 호출비·DB 쓰기/정리를 직접 좌우. **1~2시간** 유지 + 다음 보강:
  - `pg_cron` 정리잡: `revoked_at`/`absolute_expires_at` 지난 행 주기 삭제(테이블 비대화 방지).
  - 클라 갱신 **지터**로 동시 폭주 완화.
  - `refresh` 엔드포인트 레이트리밋.
- **공통 기본값: access 1시간**(두 규모 안전한 출발점). 운영 지표 보며 조정.

## 8. 확정 사항 / 결정
- access 수명: **기본 1시간**(규모별 조정 §7).
- refresh: **롤링 30일 / 절대 90일**(30일 내 접속 시 유지, 90일 절대상한).
- 회전 + 재사용 탐지(family 회수)로 refresh 탈취 대응.
- refresh는 불투명+해시저장, `app` 스키마 + RLS 정책0 + service_role 전용.

## 9. 보안 체크리스트
- [ ] refresh 원문 미저장(해시만), 응답 외 로깅 금지
- [ ] 회전 시 이전 토큰 즉시 무효 + 재사용 시 family 회수
- [ ] 정지/차단·비번변경 시 refresh 회수 연동
- [ ] `refresh`/`logout` verify_jwt=false(자체 검증) + 레이트리밋
- [ ] 대규모 시 `pg_cron` 정리잡 + 클라 지터
- [ ] 앱: refresh는 secure storage, 단일비행 갱신, 401 시 강제 로그아웃
