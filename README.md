# pmdb — PawMate Supabase 백엔드

PawMate 앱(`pmdart`)의 **Supabase 백엔드**(DB 마이그레이션 + Edge Functions) 저장소.
앱 코드와 분리해 관리한다.

- **프로젝트 ref**: `vyatppuxmpulqtxevfpk` (region: ap-northeast-2)
- 클라이언트(앱)에는 **publishable 키만** 사용. `service_role` / JWT Secret 은 절대 포함하지 않음 — Edge Function 시크릿으로만 사용.

## 구조

```
supabase/
  config.toml   # 함수별 verify_jwt 고정 (배포 드리프트 방지)
  migrations/   # DB 스키마/뷰/함수 변경 (적용 순서 = 파일명 타임스탬프)
  functions/    # Edge Functions (Deno)
    _shared/    # 공용 모듈 (CORS, Solapi SMS, JWT/refresh)
```

## 문서

- [docs/supabase-db.md](docs/supabase-db.md) — **DB 전체 레퍼런스** (2026-07-02 라이브 DB 기준): ENUM/테이블 33개/제약/인덱스, 뷰 6개, RPC 54개(+app 스키마 53개), 트리거 52개, RLS 정책 76개, 컬럼 권한, Storage, Realtime, 마이그레이션 이력 77건
- [docs/supabase-api.md](docs/supabase-api.md) — **API(Edge Functions) 레퍼런스**: 함수 15개 전체의 요청/응답/내부 로직/시크릿/레이트리밋, 커스텀 JWT + refresh 토큰 수명주기, 배포 현황
- [docs/refresh-token-flow-design.md](docs/refresh-token-flow-design.md) — refresh 토큰 설계 문서

> 아래의 마이그레이션/함수 표는 초기(2026-06-08~10) 분량만 담고 있다. 전체 최신 목록은 위 문서를 볼 것.

## 마이그레이션 (이 저장소에서 관리 시작한 분량)

| 버전 | 내용 |
|---|---|
| 20260608044442 | `signup_user` — 회원가입(bcrypt 해싱, service_role 전용) |
| 20260608051112 | `login_user` RPC + `v_post_feed` / `v_comment_feed` 커뮤니티 뷰 |
| 20260608071651 | `v_chat_rooms` 채팅방 목록 뷰 + `chat_messages` realtime 발행 |
| 20260608072435 | `v_chat_rooms` 재정의 (admin_inquiry → '고객센터' 라벨) |
| 20260608095600 | `start_direct_chat` RPC(1:1 방 find-or-create) + `v_pawing` / `v_pawmate` |
| 20260608150932 | `media` Storage 버킷(public) + 본인 폴더 업로드 RLS |
| 20260608151755 | `v_post_feed` 에 `image_url` 추가(게시글 사진) |
| 20260609051500 | 알림 자동 생성 트리거(댓글/지원/지원수락/평가 → notifications) |
| 20260610104641 | 펫 등록 시 `user_type` → `pet_owner` 자동 승격 (P0001 게시글 작성 차단 수정) |
| 20260610112605 | 지원 수락 시 나머지 지원자 자동 거절 (`tg_applications_on_accept` 보강) |
| 20260610120125 | 아이디(`username`) 비공개화(`public_profiles`·컬럼권한에서 제거) + `login_user` 가 username 반환 + 가입 아이디 중복확인 RPC `check_username_available` |

> 위 이전(`20260603*`) 기반 스키마 마이그레이션은 Supabase 프로젝트에 이미 적용되어 있으며 본 저장소 범위 밖이다.

## Edge Functions

| 함수 | 설명 | verify_jwt |
|---|---|---|
| `send-phone-code` | 전화 인증코드 발급(6자리·5분) + Solapi SMS | false |
| `verify-phone-code` | 인증코드 검증 | false |
| `signup` | 회원가입(인증 완료 번호만) → `signup_user` RPC | false |
| `login` | 아이디/비번 로그인 → 커스텀 HS256 JWT 발급 | false |

### 필요한 시크릿 (Edge Function Secrets)
- `SOLAPI_API_KEY`, `SOLAPI_API_SECRET`, `SOLAPI_SENDER` — SMS 발송
- `JWT_SECRET` — Supabase 프로젝트의 JWT Secret (login 토큰 서명/검증용)

## 배포

```bash
# 마이그레이션
supabase db push

# 함수
supabase functions deploy send-phone-code --no-verify-jwt
supabase functions deploy verify-phone-code --no-verify-jwt
supabase functions deploy signup --no-verify-jwt
supabase functions deploy login --no-verify-jwt
```
