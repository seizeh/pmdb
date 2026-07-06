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

- [docs/supabase-db.md](docs/supabase-db.md) — **DB 전체 레퍼런스** (2026-07-02 라이브 DB 기준): ENUM/테이블 36개(public 33 + app 3)/제약/인덱스/pg_cron 잡, 뷰 6개, RPC 54개(+app 스키마 53개), 트리거 52개, RLS 정책 76개, 컬럼 권한, Storage, Realtime, 마이그레이션 이력 77건
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


# PawMate 마이그레이션 문서

Supabase PostgreSQL 스키마 마이그레이션(0001~0016)을 각각 Markdown으로 정리한 문서입니다.
실제 실행 파일은 `supabase/migrations/*.sql` 에 있으며, 이 문서들은 각 마이그레이션의
**목적·배경·핵심 변경·전체 SQL·주의사항**을 담고 있어 팀 문서·산출물 제출 등에 활용할 수 있습니다.

## 적용 순서

```
0001 → 0002 → 0003 → 0004 → 0005    (초기 스키마 세트업)
     ↓
0006 → 0007 → 0008                  (보안 린트 · 전화 인증 · N:M 보호자)
     ↓
0009 → 0010 → 0011 → 0012 → 0013    (정합성 보강 · 오류 수정 · 자동 승계 · 자유글 · 입양 이전)
     ↓
0014 → 0015 → 0016                  (탈퇴자 표시 · 푸시 파이프라인 · 하트 리네임)
```

## 문서 목록

| 파일 | 제목 | 카테고리 |
|---|---|---|
| [0001](./0001_extensions_and_helpers.md) | 확장·헬퍼 함수 | 초기 세트업 |
| [0002](./0002_tables.md) | 테이블·제약 (26 tables) | 초기 세트업 |
| [0003](./0003_indexes.md) | 인덱스 전략 | 초기 세트업 |
| [0004](./0004_triggers.md) | 트리거·함수 (37 triggers) | 초기 세트업 |
| [0005](./0005_rls_and_views.md) | RLS 정책·뷰 | 초기 세트업 |
| [0006](./0006_security_lint_fixes.md) | 보안 린트 보정 | 하드닝 |
| [0007](./0007_phone_auth.md) | 전화 인증 전환 | 기능 변경 |
| [0008](./0008_pet_guardians.md) | 반려동물 N:M 보호자 | 기능 변경 |
| [0009](./0009_appointment_consistency.md) | 지원/약속 정합성 보강 | 정합성 |
| [0010](./0010_fix_applications_status_check.md) | applications.status CHECK 보정 | 버그 수정 |
| [0011](./0011_owner_succession.md) | owner 탈퇴 시 자동 승계 | 정책 |
| [0012](./0012_block_free_post_applications.md) | 자유 게시글 지원 차단 | 정책 |
| [0013](./0013_adoption_transfer.md) | 입양 자동 이전 | 기능 |
| [0014](./0014_inactive_user_visibility_and_unread_reconcile.md) | 탈퇴자 표시 + unread 보정 | 하드닝 |
| [0015](./0015_push_pipeline.md) | 푸시 알림 파이프라인 | 인프라 |
| [0016](./0016_rename_likes_to_hearts.md) | post_likes → post_hearts | 리네임 |

## 최종 스키마 규모

- 테이블 29개 (전 테이블 RLS on)
- 함수 53개 (헬퍼·트리거·RPC)
- 트리거 43개
- 인덱스 58개
- 정책 77개
