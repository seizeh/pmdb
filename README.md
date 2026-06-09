# pmdb — PawMate Supabase 백엔드

PawMate 앱(`pmdart`)의 **Supabase 백엔드**(DB 마이그레이션 + Edge Functions) 저장소.
앱 코드와 분리해 관리한다.

- **프로젝트 ref**: `vyatppuxmpulqtxevfpk` (region: ap-northeast-2)
- 클라이언트(앱)에는 **publishable 키만** 사용. `service_role` / JWT Secret 은 절대 포함하지 않음 — Edge Function 시크릿으로만 사용.

## 구조

```
supabase/
  migrations/   # DB 스키마/뷰/함수 변경 (적용 순서 = 파일명 타임스탬프)
  functions/    # Edge Functions (Deno)
    _shared/    # 공용 모듈 (CORS, Solapi SMS)
```

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
