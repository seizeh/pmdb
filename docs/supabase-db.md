# PawMate Supabase — DB 구조 및 로직 문서

- **프로젝트**: `vyatppuxmpulqtxevfpk` (PAWMATE, region `ap-northeast-2`, Postgres 17)
- **조사일**: 2026-07-02 — 라이브 DB를 직접 조회해 작성 (마이그레이션 파일이 아닌 실제 배포 상태 기준)
- **짝 문서**: [supabase-api.md](supabase-api.md) — Edge Functions(API 계층) 레퍼런스
- **구성**: §1–5 스키마(ENUM/테이블/제약/인덱스), §6–12 로직(뷰/RPC/트리거/RLS/권한/Storage/Realtime), §13 마이그레이션 이력

## 인증/신원 판별 공통 기반 (`app` 스키마)

> 이 프로젝트는 Supabase Auth 를 사용하지 않는 **자체 JWT 인증** 구조다.
> 핵심 축은 `app` 스키마의 헬퍼 함수들이다:
> - `app.uid()` — PostgREST 가 주입한 `request.jwt.claims` 의 `sub`(사용자 id)와 `tv`(token_version)를 읽어, **활성(active) 상태이고 token_version 이 일치하는** 사용자의 uuid 를 반환. 불일치/비활성/무토큰이면 NULL. 모든 RLS·뷰·RPC 의 신원 판별 기준.
> - `app.is_admin()` — `app.uid()` 사용자가 `user_type='admin'` 이고 `status='active'` 인지.
> - `app.is_pet_guardian(pet, role?)` — 해당 펫의 보호자(역할 지정 가능: 'owner'/'co_guardian') 여부.
> - `app.is_post_manager(post)` — 게시글 작성자이거나, 게시글에 연결된 펫의 보호자이거나, 관리자.
> - `app.is_room_member(room)` — 채팅방 멤버 여부.
>
> 모두 `STABLE SECURITY DEFINER`, `search_path=''` 로 정의되어 RLS 를 우회해 판별만 수행한다.

---

## 1. 개요

- **테이블 수**: `public` 34개 (이 중 `spatial_ref_sys`는 PostGIS 시스템 테이블이므로 실질 애플리케이션 테이블은 **33개**) + `app` 스키마 내부 테이블 **3개**(refresh_tokens, rate_limits, push_config — §3.8)
- **ENUM 타입**: 1개 (`facility_category`) — 대부분의 상태값은 ENUM 대신 `varchar + CHECK` 제약으로 관리됨
- **커스텀 시퀀스**: 없음 (모든 PK는 `gen_random_uuid()` 기본값의 UUID)
- **모든 테이블 PK**: UUID (`review_category_counts`, `dong_centroids` 제외 — 각각 복합 PK / 자연키 PK)

### 설치된 확장 (pg_extension)

| 확장 | 버전 | 스키마 | 용도 |
|---|---|---|---|
| pg_cron | 1.6.4 | pg_catalog | 스케줄 작업 (크론 잡) |
| pg_net | 0.20.0 | public | DB 내 비동기 HTTP 요청 (푸시/웹훅 등) |
| pg_stat_statements | 1.11 | extensions | 쿼리 성능 통계 |
| pg_trgm | 1.6 | extensions | 트라이그램 텍스트 검색 (게시글 검색) |
| pgcrypto | 1.3 | extensions | 암호화 함수 (`gen_random_uuid` 등) |
| plpgsql | 1.0 | pg_catalog | PL/pgSQL 프로시저 언어 |
| postgis | 3.3.7 | public | 지리 공간 데이터 (시설 위치 `geography`) |
| supabase_vault | 0.3.1 | vault | Supabase 시크릿 저장소 |
| uuid-ossp | 1.1 | extensions | UUID 생성 함수 |

### 테이블 그룹 요약

| 그룹 | 테이블 |
|---|---|
| 사용자 / 펫 | users, business_profiles, pets, pet_guardians, pet_guardian_invites, pet_identity_frames, pawings, user_blocks |
| 게시글 / 매칭 | posts, post_pets, post_hearts, post_views, comments, applications, appointments, reviews, review_category_counts |
| 채팅 | chat_rooms, chat_room_members, chat_messages, chat_message_deletions |
| 알림 | notifications, notification_preferences, device_tokens |
| 시설 / 위치 | facilities, facility_reviews, facility_cache, dong_centroids |
| 인증 / 관리 | phone_verifications, photo_verifications, location_verifications, reports, admin_logs |
| 시스템 (PostGIS) | spatial_ref_sys |

---

## 2. ENUM 타입

### facility_category

시설(`facilities.category`)의 분류.

| 값 | 의미 |
|---|---|
| `animal_hospital` | 동물병원 |
| `grooming` | 미용 |
| `pet_hotel` | 펫호텔 |
| `pet_cafe` | 펫카페 |
| `pet_sales` | 반려동물 판매 |

> 참고: 이 외의 모든 열거형 값(게시글 카테고리, 신청 상태, 사용자 유형 등)은 ENUM이 아닌 `varchar` 컬럼 + CHECK 제약으로 구현되어 있음.

---

## 3. 테이블 상세

## 3.1 사용자 / 펫

### public.users

서비스 회원(반려인/비반려인/사업자/관리자) 계정과 프로필, 위치 인증 상태, 읽지 않음 카운터를 관리하는 핵심 테이블.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| username | varchar | NO | | 로그인 아이디 |
| password_hash | text | NO | | 비밀번호 해시 |
| nickname | varchar | NO | | 닉네임 |
| user_type | varchar | NO | | 회원 유형 (pet_owner/no_pet/business/admin) |
| status | varchar | NO | 'active' | 계정 상태 (active/inactive/suspended) |
| address | varchar | YES | | 주소 (표시용) |
| latitude | numeric | YES | | 위도 |
| longitude | numeric | YES | | 경도 |
| is_location_verified | boolean | NO | false | 동네 인증 여부 |
| last_verified_at | timestamptz | YES | | 마지막 위치 인증 시각 |
| profile_image_url | text | YES | | 프로필 이미지 URL |
| profile_image_thumbnail_url | text | YES | | 프로필 썸네일 URL |
| profile_image_mime_type | varchar | YES | | 이미지 MIME |
| profile_image_file_size | integer | YES | | 이미지 크기(byte) |
| push_enabled | boolean | NO | true | 푸시 알림 전체 on/off |
| unread_notification_count | integer | NO | 0 | 안 읽은 알림 수 (비정규화 카운터) |
| unread_chat_count | integer | NO | 0 | 안 읽은 채팅 수 (비정규화 카운터) |
| location_verify_fail_count | smallint | NO | 0 | 위치 인증 실패 횟수 |
| location_verify_blocked_until | timestamptz | YES | | 위치 인증 차단 해제 시각 |
| deleted_at | timestamptz | YES | | 탈퇴(소프트 삭제) 시각 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |
| phone | varchar | YES | | 휴대폰 번호 |
| phone_verified | boolean | NO | false | 휴대폰 인증 여부 |
| region_code | varchar | YES | | 행정동 코드 |
| activity_radius_m | smallint | YES | | 활동 반경(m, 5000~15000) |
| token_version | integer | NO | 0 | JWT 무효화용 토큰 버전 |

- **PK**: `users_pkey` (id)
- **UNIQUE**: 함수 기반 유니크 인덱스로 구현 — `lower(username)`, `lower(nickname)`, `phone`(부분, 아래 인덱스 참조)
- **CHECK**:
  - `users_status_check`: status IN ('active','inactive','suspended')
  - `users_user_type_check`: user_type IN ('pet_owner','no_pet','business','admin')
  - `users_activity_radius_chk`: activity_radius_m IS NULL OR (5000 ≤ activity_radius_m ≤ 15000)
  - `users_unread_chat_count_nonneg`: unread_chat_count ≥ 0
  - `users_unread_notification_count_nonneg`: unread_notification_count ≥ 0
  - `users_verify_fail_count_nonneg`: location_verify_fail_count ≥ 0
- **인덱스**:
  - `users_pkey` (id, UNIQUE, btree)
  - `users_lower_username_uq` (lower(username), UNIQUE, btree)
  - `users_lower_nickname_uq` (lower(nickname), UNIQUE, btree)
  - `users_phone_uq` (phone, UNIQUE, 부분: WHERE phone IS NOT NULL)
  - `users_region_code_idx` (region_code, btree)
  - `users_user_type_idx` (user_type, btree)

### public.business_profiles

사업자 회원의 부가 프로필(상호/업종/사업장 주소). users와 1:1.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 사용자 FK (1:1) |
| business_name | varchar | NO | | 상호명 |
| business_type | varchar | YES | | 업종 |
| business_address | text | YES | | 사업장 주소 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `business_profiles_pkey` (id)
- **FK**: user_id → users.id (NO ACTION)
- **UNIQUE**: `business_profiles_user_id_key` (user_id)
- **인덱스**: `business_profiles_pkey`, `business_profiles_user_id_key` (둘 다 UNIQUE btree)

### public.pets

반려동물 프로필. 주 보호자, 사진, AI 기준 이미지(정체성 인증), 매칭 통계를 보유.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| primary_guardian_id | uuid | NO | | 주 보호자 FK(users) |
| name | varchar | NO | | 이름 |
| species | varchar | NO | | 품종(입력값) |
| gender | varchar | YES | | 성별 (male/female) |
| birth_date | date | YES | | 생일 |
| is_neutered | boolean | NO | false | 중성화 여부 |
| image_url | text | YES | | 대표 사진 URL |
| image_thumbnail_url | text | YES | | 썸네일 URL |
| image_mime_type | varchar | YES | | 이미지 MIME |
| image_file_size | integer | YES | | 이미지 크기 |
| image_width | smallint | YES | | 이미지 가로 |
| image_height | smallint | YES | | 이미지 세로 |
| bio | text | YES | | 소개 |
| pet_status | varchar | NO | 'active' | 상태 (active/transferred/deceased/deleted) |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |
| ai_ref_image_url | text | YES | | AI 기준(레퍼런스) 이미지 URL |
| ai_ref_image_path | text | YES | | AI 기준 이미지 스토리지 경로 |
| ai_ref_verification_id | uuid | YES | | 기준 이미지 검증 FK(photo_verifications) |
| ai_ref_verified_at | timestamptz | YES | | 기준 이미지 검증 시각 |
| pet_match_count | integer | NO | 0 | 매칭(동일 개체 판정) 횟수 |
| species_kind | varchar | YES | | 종 구분 (dog/cat) |
| identity_verified | boolean | NO | false | 개체 인증 완료 여부 |
| identity_verified_at | timestamptz | YES | | 개체 인증 시각 |
| ai_species | varchar | YES | | AI 판별 종 |
| ai_breed | varchar | YES | | AI 판별 품종 |
| ai_colors | text[] | YES | | AI 판별 색상 목록 |
| info_match | jsonb | YES | | 입력 정보와 AI 판별 결과 대조 |

- **PK**: `pets_pkey` (id)
- **FK**:
  - primary_guardian_id → users.id (제약명 `pets_user_id_fkey`, NO ACTION)
  - ai_ref_verification_id → photo_verifications.id (NO ACTION)
- **CHECK**:
  - `pets_gender_check`: gender IS NULL OR gender IN ('male','female')
  - `pets_pet_status_check`: pet_status IN ('active','transferred','deceased','deleted')
  - `pets_species_kind_check`: species_kind IS NULL OR species_kind IN ('dog','cat')
- **인덱스**:
  - `pets_pkey` (id, UNIQUE)
  - `pets_user_id_idx` (primary_guardian_id, btree)
  - `pets_active_idx` (primary_guardian_id, 부분: WHERE pet_status='active')

### public.pet_guardians

펫-보호자 다대다 관계 (공동 보호자 지원). role로 owner/co_guardian 구분.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| pet_id | uuid | NO | | 펫 FK |
| user_id | uuid | NO | | 보호자 FK(users) |
| role | varchar | NO | 'co_guardian' | 역할 (owner/co_guardian) |
| invited_by | uuid | YES | | 초대한 사용자 FK(users) |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `pet_guardians_pkey` (id)
- **FK**: pet_id → pets.id (**ON DELETE CASCADE**), user_id → users.id, invited_by → users.id
- **UNIQUE**: `pet_guardians_uq` (pet_id, user_id)
- **CHECK**: `pet_guardians_role_check`: role IN ('owner','co_guardian')
- **인덱스**:
  - `pet_guardians_pkey`, `pet_guardians_uq` (UNIQUE)
  - `pet_guardians_one_owner_uq` (pet_id, UNIQUE 부분: WHERE role='owner') — **펫당 owner는 1명만 허용**
  - `pet_guardians_user_idx` (user_id)

### public.pet_guardian_invites

공동 보호자 초대/요청. 전화번호 기반 초대(미가입자)와 사용자 기반 초대를 모두 지원.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| pet_id | uuid | NO | | 펫 FK |
| kind | varchar | NO | | 종류 (invite: 초대 / request: 요청) |
| inviter_id | uuid | NO | | 초대자 FK(users) |
| invitee_phone | varchar | YES | | 피초대자 전화번호 (미가입자용) |
| invitee_user_id | uuid | YES | | 피초대자 FK(users) |
| status | varchar | NO | 'pending' | 상태 (pending/accepted/declined/expired) |
| created_at | timestamptz | NO | now() | 생성 시각 |
| responded_at | timestamptz | YES | | 응답 시각 |

- **PK**: `pet_guardian_invites_pkey` (id)
- **FK**: pet_id → pets.id (**ON DELETE CASCADE**), inviter_id → users.id, invitee_user_id → users.id
- **CHECK**:
  - `pet_guardian_invites_kind_check`: kind IN ('invite','request')
  - `pet_guardian_invites_status_check`: status IN ('pending','accepted','declined','expired')
- **인덱스**:
  - `pgi_pending_user_uq` (pet_id, invitee_user_id, UNIQUE 부분: WHERE status='pending' AND invitee_user_id IS NOT NULL) — 동일 대상 중복 pending 초대 방지
  - `pgi_pending_phone_uq` (pet_id, invitee_phone, UNIQUE 부분: WHERE status='pending' AND invitee_phone IS NOT NULL)
  - `pgi_invitee_idx` (invitee_user_id, 부분: WHERE status='pending')
  - `pgi_phone_idx` (invitee_phone, 부분: WHERE status='pending')
  - `pgi_pet_idx` (pet_id, status)

### public.pet_identity_frames

펫 개체 인증용 다각도 촬영 프레임 이미지 (frame_index로 순서 관리).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| pet_id | uuid | NO | | 펫 FK |
| frame_index | smallint | NO | | 프레임 순번 |
| image_url | text | NO | | 이미지 URL |
| image_path | text | NO | | 스토리지 경로 |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `pet_identity_frames_pkey` (id)
- **FK**: pet_id → pets.id (**ON DELETE CASCADE**)
- **UNIQUE**: `pet_identity_frames_uq` (pet_id, frame_index)
- **인덱스**: `pet_identity_frames_pet_idx` (pet_id)

### public.pawings

사용자 간 팔로우("포잉") 관계.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| follower_id | uuid | NO | | 팔로우 하는 사용자 FK(users) |
| following_id | uuid | NO | | 팔로우 대상 사용자 FK(users) |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `pawings_pkey` (id)
- **FK**: follower_id → users.id, following_id → users.id
- **UNIQUE**: `pawings_uq` (follower_id, following_id)
- **CHECK**: `pawings_self_chk`: follower_id <> following_id (자기 팔로우 금지)
- **인덱스**: `pawings_following_idx` (following_id)

### public.user_blocks

사용자 차단 관계.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| blocker_id | uuid | NO | | 차단한 사용자 FK(users) |
| blocked_id | uuid | NO | | 차단당한 사용자 FK(users) |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `user_blocks_pkey` (id)
- **FK**: blocker_id → users.id, blocked_id → users.id
- **UNIQUE**: `user_blocks_uq` (blocker_id, blocked_id)
- **CHECK**: `user_blocks_self_chk`: blocker_id <> blocked_id

---

## 3.2 게시글 / 매칭

### public.posts

산책/돌봄/입양 등 매칭 게시글. 위치 프라이버시(실제/표시 좌표 분리), 카운터 비정규화, AI 반려동물 인증 연동.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 작성자 FK(users) |
| category | varchar | NO | | 카테고리 (walk_together/walk_proxy/care/adoption/give_away/free) |
| title | varchar | NO | | 제목 |
| content | text | NO | | 본문 |
| image_url | text | YES | | 첨부 이미지 URL |
| image_thumbnail_url | text | YES | | 썸네일 URL |
| image_mime_type | varchar | YES | | 이미지 MIME |
| image_file_size | integer | YES | | 이미지 크기 (≤12MB) |
| image_width | smallint | YES | | 이미지 가로 |
| image_height | smallint | YES | | 이미지 세로 |
| scheduled_at | timestamptz | YES | | 약속 예정 일시 |
| visibility_status | varchar | NO | 'visible' | 노출 상태 (visible/hidden_by_user/hidden_by_admin/deleted_by_user/deleted_by_admin) |
| progress_status | varchar | NO | 'recruiting' | 진행 상태 (recruiting/matched/completed/cancelled) |
| deleted_at | timestamptz | YES | | 삭제 시각 |
| view_count | integer | NO | 0 | 조회수 (비정규화) |
| heart_count | integer | NO | 0 | 하트 수 (비정규화) |
| comment_count | integer | NO | 0 | 댓글 수 (비정규화) |
| actual_lat | numeric | YES | | 실제 위도 (비공개) |
| actual_lng | numeric | YES | | 실제 경도 (비공개) |
| display_lat | numeric | YES | | 표시용 위도 (난독화) |
| display_lng | numeric | YES | | 표시용 경도 |
| display_address | varchar | YES | | 표시용 주소 |
| region_code | varchar | YES | | 행정동 코드 |
| location_radius_m | smallint | YES | | 위치 난독화 반경(m) |
| is_location_hidden | boolean | NO | false | 위치 숨김 여부 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |
| photo_verification_id | uuid | YES | | 사진 검증 FK(photo_verifications) |
| ai_pet_species | varchar | YES | | AI 판별 종 |
| is_pet_verified | boolean | NO | false | 반려동물 인증 게시글 여부 |

- **PK**: `posts_pkey` (id)
- **FK**: user_id → users.id, photo_verification_id → photo_verifications.id
- **CHECK**:
  - `posts_category_check`: category IN ('walk_together','walk_proxy','care','adoption','give_away','free')
  - `posts_visibility_status_check`: visibility_status IN ('visible','hidden_by_user','hidden_by_admin','deleted_by_user','deleted_by_admin')
  - `posts_progress_status_check`: progress_status IN ('recruiting','matched','completed','cancelled')
  - `posts_deleted_at_consistency`: visibility_status가 'deleted_%'면 deleted_at NOT NULL
  - `posts_image_file_size_check`: image_file_size IS NULL OR ≤ 12,582,912 (12MB)
  - `posts_view_count_check` / `posts_like_count_check` / `posts_comment_count_check`: 각 카운터 ≥ 0
- **인덱스**:
  - `posts_pkey` (id, UNIQUE)
  - `posts_list_idx` (visibility_status, progress_status, created_at DESC) — 목록 조회
  - `posts_region_idx` (region_code, progress_status, created_at DESC) — 지역 필터
  - `posts_category_idx` (category)
  - `posts_user_id_idx` (user_id)
  - `posts_display_coord_idx` (display_lat, display_lng)
  - `posts_trgm_idx` (GIN, gin_trgm_ops on `COALESCE(title,'') || ' ' || COALESCE(content,'')`) — 트라이그램 전문 검색

### public.post_pets

게시글-펫 연결 (게시글에 등장하는 펫 다대다).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| post_id | uuid | NO | | 게시글 FK |
| pet_id | uuid | NO | | 펫 FK |

- **PK**: `post_pets_pkey` (id)
- **FK**: post_id → posts.id (**ON DELETE CASCADE**), pet_id → pets.id
- **UNIQUE**: `post_pets_uq` (post_id, pet_id)
- **인덱스**: `post_pets_pet_idx` (pet_id)

### public.post_hearts

게시글 하트(좋아요). 제약/인덱스 명에 구명칭 `post_likes_*`가 남아 있음.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| post_id | uuid | NO | | 게시글 FK |
| user_id | uuid | NO | | 사용자 FK |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `post_likes_pkey` (id)
- **FK**: post_id → posts.id (**ON DELETE CASCADE**, 제약명 `post_likes_post_id_fkey`), user_id → users.id (제약명 `post_likes_user_id_fkey`)
- **UNIQUE**: `post_hearts_uq` (post_id, user_id)
- **인덱스**: `post_hearts_user_idx` (user_id)

### public.post_views

게시글 조회 기록. 시간 버킷(view_bucket) 단위로 사용자/IP별 중복 조회 방지.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| post_id | uuid | NO | | 게시글 FK |
| user_id | uuid | YES | | 사용자 FK (비로그인 시 NULL) |
| ip_hash | varchar | YES | | IP 해시 (비로그인 식별) |
| session_id | varchar | YES | | 세션 ID |
| view_bucket | timestamptz | NO | | 중복 방지용 시간 버킷 |
| viewed_at | timestamptz | NO | now() | 조회 시각 |

- **PK**: `post_views_pkey` (id)
- **FK**: post_id → posts.id (**ON DELETE CASCADE**), user_id → users.id
- **CHECK**: `post_views_identity_chk`: user_id IS NOT NULL OR ip_hash IS NOT NULL (익명이라도 식별자 필수)
- **인덱스**:
  - `post_views_user_bucket_uq` (post_id, user_id, view_bucket, UNIQUE 부분: WHERE user_id IS NOT NULL)
  - `post_views_ip_bucket_uq` (post_id, ip_hash, view_bucket, UNIQUE 부분: WHERE ip_hash IS NOT NULL)
  - `post_views_post_idx` (post_id), `post_views_viewed_idx` (viewed_at)

### public.comments

게시글 댓글 (소프트 삭제 지원).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| post_id | uuid | NO | | 게시글 FK |
| user_id | uuid | NO | | 작성자 FK |
| content | text | NO | | 내용 |
| is_deleted | boolean | NO | false | 삭제 여부 |
| deleted_at | timestamptz | YES | | 삭제 시각 |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `comments_pkey` (id)
- **FK**: post_id → posts.id, user_id → users.id (둘 다 NO ACTION)
- **인덱스**:
  - `comments_post_idx` (post_id, created_at, 부분: WHERE is_deleted=false)
  - `comments_user_idx` (user_id)

### public.applications

게시글 참여 신청. give_away 등에서 신청자가 자기 펫을 제시할 수 있음(offered_pet_id).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| post_id | uuid | NO | | 게시글 FK |
| applicant_id | uuid | NO | | 신청자 FK(users) |
| status | varchar | NO | 'pending' | 상태 (pending/accepted/rejected/cancelled/completed) |
| message | text | YES | | 신청 메시지 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |
| offered_pet_id | uuid | YES | | 신청 시 제시한 펫 FK(pets) |

- **PK**: `applications_pkey` (id)
- **FK**: post_id → posts.id, applicant_id → users.id, offered_pet_id → pets.id (모두 NO ACTION)
- **UNIQUE**: `applications_uq` (post_id, applicant_id) — 게시글당 1회 신청
- **CHECK**: `applications_status_check`: status IN ('pending','accepted','rejected','cancelled','completed')
- **인덱스**:
  - `applications_post_status_idx` (post_id, status)
  - `applications_applicant_idx` (applicant_id)
  - `applications_offered_pet_idx` (offered_pet_id, 부분: WHERE offered_pet_id IS NOT NULL)

### public.appointments

수락된 신청으로부터 생성되는 약속(만남) 레코드. application과 1:1.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| application_id | uuid | NO | | 신청 FK (1:1) |
| post_id | uuid | NO | | 게시글 FK |
| post_owner_id | uuid | NO | | 게시글 작성자 FK(users) |
| applicant_id | uuid | NO | | 신청자 FK(users) |
| status | varchar | NO | 'scheduled' | 상태 (scheduled/completed/cancelled) |
| scheduled_at | timestamptz | YES | | 약속 일시 |
| completed_at | timestamptz | YES | | 완료 시각 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `appointments_pkey` (id)
- **FK**: application_id → applications.id, post_id → posts.id, post_owner_id → users.id, applicant_id → users.id (모두 NO ACTION)
- **UNIQUE**: `appointments_application_id_key` (application_id)
- **CHECK**:
  - `appointments_status_check`: status IN ('scheduled','completed','cancelled')
  - `appointments_completed_at_chk`: status='completed'면 completed_at NOT NULL
  - `appointments_participants_distinct`: post_owner_id <> applicant_id
- **인덱스**:
  - `appointments_active_post_uq` (post_id, UNIQUE 부분: WHERE status='scheduled') — **게시글당 진행 중 약속 1건만 허용**
  - `appointments_post_idx` (post_id), `appointments_owner_idx` (post_owner_id), `appointments_applicant_idx` (applicant_id)

### public.reviews

약속 완료 후 상호 카테고리형(태그) 후기. 점수 대신 한국어 카테고리 배열 사용.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| appointment_id | uuid | NO | | 약속 FK |
| reviewer_id | uuid | NO | | 작성자 FK(users) |
| reviewee_id | uuid | NO | | 대상자 FK(users) |
| categories | text[] | NO | | 후기 카테고리 배열 |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `reviews_pkey` (id)
- **FK**: appointment_id → appointments.id, reviewer_id → users.id, reviewee_id → users.id
- **UNIQUE**: `reviews_uq` (appointment_id, reviewer_id) — 약속당 1인 1후기
- **CHECK**:
  - `reviews_allowed_chk`: categories ⊆ {'친절해요','약속을잘지켜요','반려동물이순해요','준비성이좋아요','불친절해요','약속을잘안지켜요','반려동물이사나워요','준비성이아쉬워요'}
  - `reviews_len_chk`: 1 ≤ array_length(categories) ≤ 4
  - `reviews_excl_kind`: '친절해요'와 '불친절해요' 동시 선택 금지
  - `reviews_excl_promise`: '약속을잘지켜요'와 '약속을잘안지켜요' 동시 선택 금지
  - `reviews_excl_temper`: '반려동물이순해요'와 '반려동물이사나워요' 동시 선택 금지
  - `reviews_excl_prepared`: '준비성이좋아요'와 '준비성이아쉬워요' 동시 선택 금지
  - `reviews_self_chk`: reviewer_id <> reviewee_id
- **인덱스**: `reviews_appointment_idx` (appointment_id), `reviews_reviewee_idx` (reviewee_id)

### public.review_category_counts

사용자별 후기 카테고리 누적 카운트 (집계 캐시 테이블). 복합 PK, id 컬럼 없음.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| user_id | uuid | NO | | 사용자 FK (PK 일부) |
| category | varchar | NO | | 후기 카테고리 (PK 일부) |
| count | integer | NO | 0 | 누적 횟수 |
| updated_at | timestamptz | YES | | 갱신 시각 |

- **PK**: `review_category_counts_pk` (user_id, category)
- **FK**: user_id → users.id
- **CHECK**: `review_category_counts_count_check`: count ≥ 0

---

## 3.3 채팅

### public.chat_rooms

채팅방. canonical_key로 동일 참가자 조합의 방 중복 생성 방지, 마지막 메시지 정보 비정규화.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| room_type | varchar | NO | 'direct' | 방 유형 (direct/admin_inquiry) |
| canonical_key | varchar | NO | | 참가자 조합 정규화 키 |
| last_message_id | uuid | YES | | 마지막 메시지 FK |
| last_message_at | timestamptz | YES | | 마지막 메시지 시각 |
| last_message_preview | varchar | YES | | 마지막 메시지 미리보기 |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `chat_rooms_pkey` (id)
- **FK**: last_message_id → chat_messages.id (**ON DELETE SET NULL**, 제약명 `chat_rooms_last_message_fk`)
- **UNIQUE**: `chat_rooms_canonical_key_key` (canonical_key)
- **CHECK**: `chat_rooms_room_type_check`: room_type IN ('direct','admin_inquiry')
- **인덱스**: `chat_rooms_last_msg_idx` (last_message_at DESC)

### public.chat_room_members

채팅방 참가자와 읽음 커서(last_read_message_id).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| room_id | uuid | NO | | 방 FK |
| user_id | uuid | NO | | 사용자 FK |
| last_read_message_id | uuid | YES | | 마지막 읽은 메시지 FK |
| joined_at | timestamptz | NO | now() | 입장 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `chat_room_members_pkey` (id)
- **FK**: room_id → chat_rooms.id (**ON DELETE CASCADE**), user_id → users.id, last_read_message_id → chat_messages.id (**ON DELETE SET NULL**)
- **UNIQUE**: `chat_room_members_uq` (room_id, user_id)
- **인덱스**: `chat_room_members_user_idx` (user_id)

### public.chat_messages

채팅 메시지 (텍스트/이미지, 소프트 삭제).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| room_id | uuid | NO | | 방 FK |
| sender_id | uuid | NO | | 발신자 FK(users) |
| content | text | YES | | 텍스트 내용 |
| image_url | text | YES | | 이미지 URL |
| image_thumbnail_url | text | YES | | 썸네일 URL |
| image_mime_type | varchar | YES | | 이미지 MIME |
| image_file_size | integer | YES | | 이미지 크기 (≤10MB) |
| image_width | smallint | YES | | 이미지 가로 |
| image_height | smallint | YES | | 이미지 세로 |
| is_deleted | boolean | NO | false | 전체 삭제 여부 |
| deleted_at | timestamptz | YES | | 삭제 시각 |
| created_at | timestamptz | NO | now() | 발신 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `chat_messages_pkey` (id)
- **FK**: room_id → chat_rooms.id (**ON DELETE CASCADE**), sender_id → users.id
- **CHECK**:
  - `chat_messages_not_empty`: content IS NOT NULL OR image_url IS NOT NULL (빈 메시지 금지)
  - `chat_messages_content_not_blank`: content IS NULL OR trim 후 길이 > 0
  - `chat_messages_image_file_size_check`: image_file_size IS NULL OR ≤ 10,485,760 (10MB)
- **인덱스**: `chat_messages_room_order_idx` (room_id, created_at, id) — 방별 시간순 페이지네이션

### public.chat_message_deletions

사용자별 메시지 삭제(나에게만 삭제) 기록.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| message_id | uuid | NO | | 메시지 FK |
| user_id | uuid | NO | | 삭제한 사용자 FK |
| deleted_at | timestamptz | NO | now() | 삭제 시각 |

- **PK**: `chat_message_deletions_pkey` (id)
- **FK**: message_id → chat_messages.id (**ON DELETE CASCADE**), user_id → users.id
- **UNIQUE**: `chat_message_deletions_uq` (message_id, user_id)

---

## 3.4 알림

### public.notifications

인앱 알림 + 푸시 발송 큐(push_status 파이프라인) 겸용. 그룹 키로 미읽음 알림 집계(aggregated_count) 지원.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 수신자 FK(users) |
| actor_user_id | uuid | YES | | 행위자 FK(users) |
| notification_type | varchar | NO | | 알림 유형 (13종, CHECK 참조) |
| is_system | boolean | NO | false | 시스템 알림 여부 |
| priority | varchar | NO | 'normal' | 우선순위 (high/normal/low) |
| is_silent | boolean | NO | false | 무음 알림 여부 |
| notification_group_key | varchar | YES | | 집계용 그룹 키 |
| title | text | YES | | 제목 |
| body | text | YES | | 본문 |
| aggregated_count | integer | NO | 1 | 집계 건수 (≥1) |
| resource_type | varchar | YES | | 연결 리소스 유형 (post/comment/chat_room/appointment) |
| resource_id | uuid | YES | | 연결 리소스 ID |
| is_read | boolean | NO | false | 읽음 여부 |
| read_at | timestamptz | YES | | 읽은 시각 |
| push_sent | boolean | YES | | (레거시) 푸시 발송 여부 |
| push_sent_at | timestamptz | YES | | 푸시 발송 시각 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |
| push_status | varchar | NO | 'pending' | 푸시 상태 (pending/sending/sent/failed/skipped) |
| push_attempts | smallint | NO | 0 | 푸시 시도 횟수 |
| push_error | text | YES | | 푸시 실패 사유 |

- **PK**: `notifications_pkey` (id)
- **FK**: user_id → users.id, actor_user_id → users.id
- **CHECK**:
  - `notifications_notification_type_check`: notification_type IN ('chat_message','post_application','post_comment','pawing_new_post','application_accepted','application_accepted_by_co','review_received','guardian_invite','system_notice','location_expired','chat_read_receipt','unread_sync','security_login')
  - `notifications_priority_check`: priority IN ('high','normal','low')
  - `notifications_push_status_check`: push_status IN ('pending','sending','sent','failed','skipped')
  - `notifications_resource_type_check`: resource_type IS NULL OR IN ('post','comment','chat_room','appointment')
  - `notifications_aggregated_count_check`: aggregated_count ≥ 1
  - `notifications_push_attempts_check`: push_attempts ≥ 0
- **인덱스**:
  - `notifications_group_uq` (user_id, notification_group_key, UNIQUE 부분: WHERE is_read=false AND notification_group_key IS NOT NULL) — 미읽음 알림 그룹당 1행으로 집계
  - `notifications_push_pending_idx` (created_at, 부분: WHERE push_status='pending') — 푸시 발송 큐 스캔
  - `notifications_unread_idx` (user_id, created_at DESC, 부분: WHERE is_read=false)
  - `notifications_user_created_idx` (user_id, created_at DESC)

### public.notification_preferences

사용자별 알림 유형 on/off 설정. users와 1:1.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 사용자 FK (1:1) |
| chat_message | boolean | YES | true | 채팅 메시지 알림 |
| post_application | boolean | YES | true | 신청 알림 |
| post_comment | boolean | YES | true | 댓글 알림 |
| pawing_new_post | boolean | YES | true | 팔로잉 새 글 알림 |
| application_accepted | boolean | YES | true | 신청 수락 알림 |
| review_received | boolean | YES | true | 후기 수신 알림 |
| system_notice | boolean | YES | true | 시스템 공지 알림 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `notification_preferences_pkey` (id)
- **FK**: user_id → users.id
- **UNIQUE**: `notification_preferences_user_id_key` (user_id)

### public.device_tokens

푸시 발송용 디바이스 토큰 (FCM/APNs). 실패 카운트로 무효 토큰 정리.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 사용자 FK |
| token | text | NO | | 디바이스 토큰 |
| platform | varchar | NO | | 플랫폼 (ios/android) |
| device_name | varchar | YES | | 기기명 |
| is_active | boolean | NO | true | 활성 여부 |
| failure_count | smallint | NO | 0 | 발송 실패 횟수 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `device_tokens_pkey` (id)
- **FK**: user_id → users.id
- **UNIQUE**: `device_tokens_token_key` (token) — 한때 중복 유니크 인덱스 `device_tokens_token_uq`가 있었으나 `20260702130000`에서 제거됨
- **CHECK**:
  - `device_tokens_platform_check`: platform IN ('ios','android')
  - `device_tokens_failure_count_check`: failure_count ≥ 0
- **인덱스**: `device_tokens_active_idx` (user_id, 부분: WHERE is_active=true)

---

## 3.5 시설 / 위치

### public.facilities

공공데이터 기반 반려동물 시설 마스터. PostGIS `geography` 좌표와 평점 집계 보유.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| category | facility_category | NO | | 시설 분류 (ENUM) |
| source | varchar | NO | | 데이터 출처 |
| ext_id | varchar | NO | | 출처 측 고유 ID |
| name | varchar | NO | | 시설명 |
| address | text | YES | | 주소 |
| phone | varchar | YES | | 전화번호 |
| biz_status | varchar | YES | | 영업 상태(원본값) |
| is_open | boolean | NO | true | 영업 중 여부 |
| license_date | date | YES | | 인허가일 |
| region_code | varchar | YES | | 행정동 코드 |
| geom | geography | YES | | 위치 (PostGIS geography) |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | NO | now() | 수정 시각 |
| avg_rating | numeric | NO | 0 | 평균 별점 (집계) |
| review_count | integer | NO | 0 | 리뷰 수 (집계) |

- **PK**: `facilities_pkey` (id)
- **UNIQUE**: `facilities_src_uq` (source, ext_id) — 출처별 중복 적재 방지
- **인덱스**:
  - `facilities_geom_gix` (geom, **GiST**) — 공간 근접 검색
  - `facilities_cat_idx` (category, 부분: WHERE is_open)

### public.facility_reviews

시설 리뷰 (별점 1~5, 사진 최대 5장, 시설당 1인 1리뷰).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| facility_id | uuid | NO | | 시설 FK |
| user_id | uuid | NO | | 작성자 FK |
| rating | smallint | NO | | 별점 (1~5) |
| content | text | YES | | 내용 |
| photo_urls | text[] | NO | '{}' | 사진 URL 배열 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| updated_at | timestamptz | NO | now() | 수정 시각 |
| photo_paths | text[] | NO | '{}' | 사진 스토리지 경로 배열 |
| visibility_status | varchar | NO | 'visible' | 노출 상태 |

- **PK**: `facility_reviews_pkey` (id)
- **FK**: facility_id → facilities.id (**ON DELETE CASCADE**), user_id → users.id (**ON DELETE CASCADE**)
- **UNIQUE**: `facility_reviews_facility_id_user_id_key` (facility_id, user_id)
- **CHECK**:
  - `facility_reviews_rating_check`: 1 ≤ rating ≤ 5
  - `facility_reviews_photos_max`: array_length(photo_paths) ≤ 5
- **인덱스**: `facility_reviews_facility_idx` (facility_id, created_at DESC)

### public.facility_cache

외부 지도 API(카카오 등) 장소 검색 결과 캐시 (TTL: expires_at). FK 없음.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| kakao_place_id | varchar | NO | | 외부 장소 ID |
| source_provider | varchar | NO | 'kakao' | 제공자 (kakao/naver/google) |
| name | varchar | NO | | 장소명 |
| category | varchar | NO | | 카테고리 |
| address | text | YES | | 주소 |
| lat | numeric | NO | | 위도 |
| lng | numeric | NO | | 경도 |
| phone | varchar | YES | | 전화번호 |
| website_url | text | YES | | 웹사이트 |
| business_hours | jsonb | YES | | 영업시간 |
| thumbnail_url | text | YES | | 썸네일 |
| is_open_now | boolean | YES | | 현재 영업 여부 |
| open_status_updated_at | timestamptz | YES | | 영업 상태 갱신 시각 |
| cached_at | timestamptz | NO | now() | 캐시 저장 시각 |
| expires_at | timestamptz | NO | | 캐시 만료 시각 |
| last_api_sync_at | timestamptz | YES | | 마지막 API 동기화 시각 |
| sync_fail_count | smallint | NO | 0 | 동기화 실패 횟수 |

- **PK**: `facility_cache_pkey` (id)
- **UNIQUE**: `facility_cache_uq` (kakao_place_id, source_provider)
- **CHECK**:
  - `facility_cache_source_provider_check`: source_provider IN ('kakao','naver','google')
  - `facility_cache_sync_fail_count_check`: sync_fail_count ≥ 0
- **인덱스**: `facility_cache_category_idx` (category), `facility_cache_coord_idx` (lat, lng), `facility_cache_expires_idx` (expires_at)

### public.dong_centroids

행정동 중심 좌표 룩업 테이블 (region_code가 자연키 PK). FK 없음.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| region_code | varchar | NO | | 행정동 코드 (PK) |
| name | text | YES | | 동 이름 |
| lng | double precision | NO | | 중심 경도 |
| lat | double precision | NO | | 중심 위도 |
| source | varchar | NO | 'geocode' | 좌표 출처 |
| updated_at | timestamptz | NO | now() | 갱신 시각 |

- **PK**: `dong_centroids_pkey` (region_code)

---

## 3.6 인증 / 관리

### public.phone_verifications

SMS 휴대폰 인증 코드 (회원가입/비밀번호 재설정). FK 없음 — 가입 전 사용자도 대상.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| phone | varchar | NO | | 휴대폰 번호 |
| code | varchar | NO | | 인증 코드 |
| purpose | varchar | NO | 'signup' | 용도 (signup/password_reset) |
| expires_at | timestamptz | NO | | 만료 시각 |
| is_used | boolean | NO | false | 사용 여부 |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `phone_verifications_pkey` (id)
- **CHECK**: `phone_verifications_purpose_check`: purpose IN ('signup','password_reset')
- **인덱스**: `phone_verifications_lookup_idx` (phone, purpose, created_at DESC), `phone_verifications_expires_idx` (expires_at)

### public.photo_verifications

AI 반려동물 사진 검증 기록. 실사/생성 이미지 판별 점수, 개체 매칭 점수, 촬영 위치 대조를 포함하며 1회성 토큰(consumed_at)으로 소비됨.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 사용자 FK |
| shot_lat | numeric | YES | | 촬영 위도 |
| shot_lng | numeric | YES | | 촬영 경도 |
| shot_accuracy_m | smallint | YES | | 위치 정확도(m) |
| region_code | varchar | YES | | 촬영 행정동 코드 |
| region_matched | boolean | NO | false | 활동 지역 일치 여부 |
| ai_species | varchar | YES | | AI 판별 종 |
| ai_dog_real | numeric | NO | 0 | 실제 개 확률 |
| ai_cat_real | numeric | NO | 0 | 실제 고양이 확률 |
| ai_dog_fake | numeric | NO | 0 | 가짜(생성) 개 확률 |
| ai_cat_fake | numeric | NO | 0 | 가짜(생성) 고양이 확률 |
| ai_pass | boolean | NO | false | AI 판별 통과 여부 |
| ai_reason | varchar | YES | | AI 판정 사유 |
| image_url | text | YES | | 검증 이미지 URL |
| image_path | text | YES | | 스토리지 경로 |
| result | varchar | NO | | 최종 결과 (pass/fail) |
| fail_reason | varchar | YES | | 실패 사유 |
| consumed_at | timestamptz | YES | | 토큰 소비 시각 (게시글 작성 등에 사용됨) |
| expires_at | timestamptz | NO | | 토큰 만료 시각 |
| created_at | timestamptz | NO | now() | 생성 시각 |
| pet_id | uuid | YES | | 대상 펫 FK |
| purpose | varchar | NO | 'post' | 용도 (reference: 펫 기준 이미지 / post: 게시글) |
| ai_match_score | numeric | YES | | 기준 이미지와 개체 매칭 점수 |
| ai_matched | boolean | NO | false | 개체 일치 여부 |
| ai_match_reason | varchar | YES | | 매칭 판정 사유 |

- **PK**: `photo_verifications_pkey` (id)
- **FK**: user_id → users.id, pet_id → pets.id
- **CHECK**:
  - `photo_verifications_result_check`: result IN ('pass','fail')
  - `photo_verifications_purpose_check`: purpose IN ('reference','post')
- **인덱스**:
  - `photo_verifications_user_idx` (user_id, created_at DESC)
  - `photo_verifications_token_open_idx` (id, 부분: WHERE consumed_at IS NULL AND result='pass') — 미소비 통과 토큰 조회

### public.location_verifications

동네(위치) 인증 시도 이력.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | 사용자 FK |
| verified_lat | numeric | NO | | 인증 시도 위도 |
| verified_lng | numeric | NO | | 인증 시도 경도 |
| verified_radius_meters | smallint | NO | | 허용 반경(m) |
| result | varchar | NO | | 결과 (success/failed/blocked) |
| fail_reason | varchar | YES | | 실패 사유 |
| created_at | timestamptz | NO | now() | 시도 시각 |

- **PK**: `location_verifications_pkey` (id)
- **FK**: user_id → users.id
- **CHECK**: `location_verifications_result_check`: result IN ('success','failed','blocked')
- **인덱스**: `location_verifications_user_idx` (user_id, created_at DESC)

### public.reports

게시글/댓글/채팅/사용자 신고. 카테고리는 한국어 텍스트 배열, target은 다형성(target_type + target_id, FK 없음).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| reporter_id | uuid | NO | | 신고자 FK(users) |
| target_type | varchar | NO | | 대상 유형 (post/comment/chat_message/user) |
| target_id | uuid | NO | | 대상 ID (다형성, FK 없음) |
| categories | text[] | NO | | 신고 사유 배열 |
| extra_description | text | YES | | 추가 설명 |
| status | varchar | NO | 'submitted' | 처리 상태 (submitted/reviewing/resolved/dismissed) |
| reviewed_by | uuid | YES | | 처리 관리자 FK(users) |
| reviewed_at | timestamptz | YES | | 처리 시각 |
| created_at | timestamptz | NO | now() | 신고 시각 |
| updated_at | timestamptz | YES | | 수정 시각 |

- **PK**: `reports_pkey` (id)
- **FK**: reporter_id → users.id, reviewed_by → users.id
- **UNIQUE**: `reports_uq` (reporter_id, target_id, target_type)
- **CHECK**:
  - `reports_target_type_check`: target_type IN ('post','comment','chat_message','user')
  - `reports_status_check`: status IN ('submitted','reviewing','resolved','dismissed')
  - `reports_categories_allowed`: categories ⊆ {'욕설비방','허위정보','사기의심','부적절한내용','약속불이행','기타','카테고리와 무관해요','실제 반려동물이 아니에요','기타(직접작성)'}
  - `reports_categories_len`: array_length(categories) ≥ 1
  - `reports_extra_required`: '기타' 또는 '기타(직접작성)' 선택 시 extra_description 필수(공백 불가)
- **인덱스**:
  - `reports_one_open_per_target` (reporter_id, target_type, target_id, UNIQUE 부분: WHERE status IN ('submitted','reviewing')) — 동일 대상 중복 미처리 신고 방지
  - `reports_status_idx` (status), `reports_target_idx` (target_type, target_id)

### public.admin_logs

관리자 행위 감사 로그 (대상은 다형성, 상세는 jsonb).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| admin_id | uuid | NO | | 관리자 FK(users) |
| action_type | varchar | NO | | 행위 유형 |
| target_type | varchar | YES | | 대상 유형 |
| target_id | uuid | YES | | 대상 ID |
| detail | jsonb | YES | | 상세 내용 |
| created_at | timestamptz | NO | now() | 기록 시각 |

- **PK**: `admin_logs_pkey` (id)
- **FK**: admin_id → users.id
- **인덱스**: `admin_logs_admin_idx` (admin_id, created_at DESC), `admin_logs_target_idx` (target_type, target_id)

---

## 3.7 시스템 테이블

### public.spatial_ref_sys

PostGIS 확장이 설치하는 좌표계(SRID) 참조 시스템 테이블. 애플리케이션 데이터가 아니므로 상세 생략 (PK: srid).

## 3.8 `app` 스키마 테이블

인증 인프라 전용 내부 테이블 3개. 클라이언트(PostgREST)에 노출되지 않으며(`app` 스키마는 API 스키마가 아님), SECURITY DEFINER 함수와 Edge Function(service_role)만 접근한다. RLS 없이 스키마 격리로 보호.

### app.refresh_tokens

refresh 토큰 저장소 (설계: `docs/refresh-token-flow-design.md`). 원문이 아닌 **해시(token_hash)** 만 저장.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | `gen_random_uuid()` | PK |
| user_id | uuid | NO | | FK → public.users.id (ON DELETE CASCADE) |
| token_hash | text | NO | | 토큰 해시. UNIQUE |
| family_id | uuid | NO | | 회전 체인(기기 세션) 식별자 — 재사용 감지 시 family 전체 회수 |
| issued_at | timestamptz | NO | `now()` | |
| expires_at | timestamptz | NO | | 슬라이딩 만료 (발급 +30일) |
| absolute_expires_at | timestamptz | NO | | 절대 만료 (family 최초 발급 +90일) |
| revoked_at | timestamptz | YES | | 회수 시각 (grace 30초 판정에 사용) |
| replaced_by | uuid | YES | | 회전으로 대체한 토큰 id. FK → 자기참조 (ON DELETE SET NULL) |
| user_agent | text | YES | | 발급 기기 식별 참고용 |

- **인덱스**: `refresh_tokens_token_hash_key`(UNIQUE, token_hash), `refresh_tokens_family_idx`(family_id), `refresh_tokens_user_idx`(user_id)
- 만료·오래 회수된 행은 pg_cron `auth-cleanup` 잡이 주기 삭제 (→ 아래 pg_cron 잡, §13 `20260701150000`)

### app.rate_limits

분 단위 버킷 레이트리밋 카운터 (`app.rate_limit_hit` 함수가 사용, login/refresh 등).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| bucket | text | NO | | PK. 예: `login:<username>:<분>`, `login_ip:<ip>:<분>` |
| count | integer | NO | `0` | 버킷 내 시도 횟수 |
| expires_at | timestamptz | NO | | 버킷 만료 — `rate_limits_expires_idx` 인덱스, 기회적/크론 정리 대상 |

### app.push_config

푸시 발송 웹훅 설정 싱글턴 (트리거 `trg_notifications_push`·크론 `push-sweep`이 참조).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | boolean | NO | `true` | PK + `CHECK (id)` — 항상 true 단일 행 강제(싱글턴) |
| function_url | text | NO | | `send-push` Edge Function URL |
| trigger_secret | text | NO | `encode(gen_random_bytes(24),'hex')` | `x-push-secret` 헤더 값 (send-push 의 `PUSH_TRIGGER_SECRET` 과 일치해야 함) |

### pg_cron 스케줄 잡

| 잡 이름 | 스케줄 | 동작 |
|---|---|---|
| `auth-cleanup` | `17 * * * *` (매시 17분) | `app.cleanup_auth()` — 만료/오래 회수된 refresh_tokens + 만료 rate_limits 삭제 |
| `push-sweep` | `* * * * *` (매분) | `app.push_config`의 URL 로 `net.http_post` — pending 알림 재시도/누락 보완 스윕 (§8 트리거의 즉시 발사와 이중화) |

---

## 4. 시퀀스

`public` 스키마에 커스텀 시퀀스 없음. 모든 식별자는 `gen_random_uuid()` 기반 UUID.

---

## 5. 설계 특징 요약

- **ENUM 최소화**: `facility_category` 1개만 ENUM이고, 나머지 열거값은 전부 varchar + CHECK로 관리 → 값 추가 시 마이그레이션이 간단.
- **부분 유니크 인덱스로 비즈니스 규칙 구현**: 펫당 owner 1명, 게시글당 진행 중 약속 1건, 미읽음 알림 그룹 집계, 미처리 신고 중복 방지, pending 초대 중복 방지 등.
- **비정규화 카운터**: posts(view/heart/comment), users(unread_*), facilities(avg_rating/review_count), review_category_counts.
- **소프트 삭제**: users.deleted_at, posts.visibility_status+deleted_at, comments.is_deleted, chat_messages.is_deleted (+사용자별 삭제 chat_message_deletions).
- **한국어 도메인 값**: reviews.categories와 reports.categories의 CHECK 제약이 한국어 리터럴 배열을 직접 검증.
- **위치 프라이버시**: posts의 actual_* / display_* 좌표 분리, location_radius_m 난독화 반경.
- **정리 대상 후보**: `post_hearts`의 제약/인덱스 명이 구명칭 `post_likes_*`로 남아 있음. (`device_tokens.token`의 중복 유니크 인덱스는 `20260702130000`에서 정리 완료)

---

## 6. 뷰(Views)

public 스키마의 애플리케이션 뷰는 6개다. (`geography_columns`, `geometry_columns` 는 PostGIS 확장이 만든 시스템 뷰이므로 제외.)
모든 뷰는 `anon`/`authenticated` 에 SELECT 권한이 있으며, 내부적으로 `app.uid()` 를 사용하므로 **유효 JWT 가 없으면 "내 것" 관련 컬럼은 비거나 0행**이 된다.

### 6.1. `public_profiles` — 공개 프로필 뷰

```sql
SELECT id, nickname, user_type, profile_image_url, profile_image_thumbnail_url,
       address, is_location_verified, created_at, activity_radius_m
  FROM users u;
```

- **무엇을 반환**: `users` 테이블에서 **공개해도 되는 컬럼만** 골라낸 프로필 뷰. `username`(로그인 ID), `phone`, `password_hash`, 좌표(`latitude`/`longitude`) 등 민감 컬럼은 노출되지 않는다.
- **용도**: 다른 뷰(v_post_feed, v_comment_feed, v_pawing, v_pawmate, v_chat_rooms)와 RPC(facility_reviews_of)가 작성자/상대방 프로필을 조인할 때 사용하는 안전한 조인 대상. 클라이언트가 타인 프로필을 조회할 때도 이 뷰를 쓴다.
- 뷰는 소유자 권한으로 실행되므로 기반 테이블 `users` 의 RLS(`suspended` 숨김)와 별개로 동작하지만, 선택 컬럼 자체가 안전한 것만 있다.

### 6.2. `v_post_feed` — 게시글 피드 뷰

```sql
SELECT p.id, p.category, p.title, p.content, p.user_id,
       pr.nickname AS author_nickname, pr.user_type AS author_user_type,
       p.created_at, p.scheduled_at, p.display_address AS location,
       p.heart_count, p.comment_count, p.view_count, p.progress_status,
       (EXISTS (SELECT 1 FROM post_hearts h
                 WHERE h.post_id = p.id AND h.user_id = app.uid())) AS hearted,
       p.image_url, p.region_code, pr.address AS author_address
  FROM posts p
  LEFT JOIN public_profiles pr ON pr.id = p.user_id
 WHERE p.visibility_status = 'visible'
    OR p.visibility_status = 'hidden_by_user' AND p.user_id = app.uid()
    OR app.is_admin();
```

- **무엇을 반환**: 피드 화면에 필요한 게시글 1행 요약 — 작성자 닉네임/유형/주소, 각종 카운트, 진행 상태, 그리고 **현재 사용자가 하트를 눌렀는지(`hearted`)** 를 포함.
- **가시성 규칙**: `visible` 게시글은 모두에게, `hidden_by_user` 는 작성자 본인에게만, 관리자는 전부 조회. (연산자 우선순위상 `visible OR (hidden_by_user AND 본인) OR admin` 으로 평가됨.)
- **용도**: 홈/카테고리별 피드 목록, 게시글 상세 헤더. `feed_region_codes()` RPC 와 조합해 동네 반경 필터링.

### 6.3. `v_comment_feed` — 댓글 피드 뷰

```sql
SELECT c.id, c.post_id, c.user_id, c.content, c.created_at,
       pr.nickname AS author_nickname
  FROM comments c
  LEFT JOIN public_profiles pr ON pr.id = c.user_id
 WHERE c.is_deleted = false;
```

- **무엇을 반환**: 삭제되지 않은 댓글 + 작성자 닉네임.
- **용도**: 게시글 상세의 댓글 목록. soft delete(`is_deleted=true`)된 댓글은 자동으로 제외된다.

### 6.4. `v_chat_rooms` — 내 채팅방 목록 뷰

```sql
SELECT r.id, r.last_message_preview, r.last_message_at,
       COALESCE((SELECT pr.nickname
                   FROM chat_room_members m2
                   JOIN public_profiles pr ON pr.id = m2.user_id
                   JOIN users u2 ON u2.id = m2.user_id
                  WHERE m2.room_id = r.id AND m2.user_id <> app.uid()
                    AND (r.room_type <> 'admin_inquiry' OR u2.user_type <> 'admin')
                  LIMIT 1),
                CASE WHEN r.room_type = 'admin_inquiry' THEN '고객센터'
                     ELSE '알 수 없음' END) AS other_nickname,
       (SELECT m2.user_id FROM chat_room_members m2
          JOIN users u2 ON u2.id = m2.user_id
         WHERE m2.room_id = r.id AND m2.user_id <> app.uid()
           AND (r.room_type <> 'admin_inquiry' OR u2.user_type <> 'admin')
         LIMIT 1) AS other_user_id,
       (SELECT count(*) FROM chat_messages cm
         WHERE cm.room_id = r.id AND cm.is_deleted = false
           AND cm.sender_id <> app.uid()
           AND (m.last_read_message_id IS NULL
                OR cm.created_at > (SELECT lr.created_at FROM chat_messages lr
                                     WHERE lr.id = m.last_read_message_id))) AS unread_count
  FROM chat_room_members m
  JOIN chat_rooms r ON r.id = m.room_id
 WHERE m.user_id = app.uid();
```

- **무엇을 반환**: **현재 로그인 사용자가 속한** 채팅방 목록. 방마다 마지막 메시지 미리보기/시각, 상대방 닉네임·id, 미읽음 수.
- **특이점**:
  - 상대방을 고를 때 `admin_inquiry`(고객센터) 방에서는 admin 계정을 상대로 잡지 않으며, 상대가 없으면 방 유형에 따라 `'고객센터'` 또는 `'알 수 없음'` 으로 표기.
  - `unread_count` 는 내 `last_read_message_id` 기준으로 이후에 온 상대 메시지(삭제 제외)를 카운트.
- **용도**: 채팅 탭의 방 목록 화면.

### 6.5. `v_pawing` — 내가 팔로우하는 목록(포잉)

```sql
SELECT pr.id AS user_id, pr.nickname, pr.user_type, p.created_at
  FROM pawings p
  JOIN public_profiles pr ON pr.id = p.following_id
 WHERE p.follower_id = app.uid();
```

- **무엇을 반환**: 내가(=`app.uid()`) 팔로우(포잉)한 사용자들의 프로필 요약 + 팔로우 시각.
- **용도**: "내 포잉" 목록 화면.

### 6.6. `v_pawmate` — 나를 팔로우하는 목록(포메이트)

```sql
SELECT pr.id AS user_id, pr.nickname, pr.user_type, p.created_at,
       (EXISTS (SELECT 1 FROM pawings me
                 WHERE me.follower_id = app.uid()
                   AND me.following_id = p.follower_id)) AS i_follow_back
  FROM pawings p
  JOIN public_profiles pr ON pr.id = p.follower_id
 WHERE p.following_id = app.uid();
```

- **무엇을 반환**: 나를 팔로우하는 사용자 목록 + **내가 맞팔로우 중인지(`i_follow_back`)**.
- **용도**: "내 포메이트" 목록 화면(맞팔 버튼 상태 표시).

---

## 7. 데이터베이스 함수(RPC)

public 스키마에 **54개**의 함수가 있다(PostGIS 확장 함수 제외, 이벤트 트리거 함수 `rls_auto_enable` 포함).
거의 전부 `SECURITY DEFINER` + `SET search_path` 고정. 실행 권한(EXECUTE) 관점에서 두 부류로 나뉜다 — §10 참조:

- **클라이언트 호출 가능(anon/authenticated EXECUTE)**: 일반 RPC.
- **service_role 전용**: 인증/토큰/검증 기록/푸시 파이프라인 등 서버(Edge Function·백엔드)만 호출.

아래는 도메인별 전체 목록이다. (표기: `[SD]` = SECURITY DEFINER, `[svc]` = service_role 전용)

### 7.1. 인증·계정 (Auth)

#### `signup_user(p_username, p_password, p_nickname, p_user_type, p_phone) → uuid` [SD][svc]
회원가입. 로직:
1. `phone_verifications` 에 해당 전화의 `purpose='signup'`, `is_used=true`, 30분 이내 레코드가 없으면 `phone_not_verified`(P0001) 예외.
2. username/nickname(소문자 비교)/phone 중복이면 각각 `username_taken`/`nickname_taken`/`phone_taken`(P0001).
3. `extensions.crypt(p_password, gen_salt('bf', 12))` 로 bcrypt 해싱 후 `users` INSERT(`phone_verified=true`), 새 id 반환.
- 부수효과: `trg_users_after_insert` 트리거가 알림 설정 기본행·고객센터 채팅방·대기 중 보호자 초대 연결을 자동 생성(§8 참조).

#### `login_user(p_username, p_password) → TABLE(id, username, nickname, user_type)` [SD]
- username(대소문자 무시) + `status='active'` + bcrypt 검증(`crypt(p_password, password_hash)`)이 맞는 행을 반환. 실패 시 0행.
- EXECUTE: anon/authenticated 가능(로그인 진입점). 반환값을 바탕으로 서버가 JWT 발급.

#### `check_username_available(p_username) → boolean` [SD]
- `lower(username)` 중복이 없으면 true. 가입 폼의 아이디 중복확인용. anon 호출 가능.

#### `reset_password_user(p_phone, p_new_password) → uuid` [SD][svc]
비밀번호 재설정:
1. 새 비밀번호 규칙 검사(8자 이상 + 영문 + 숫자) 실패 시 `invalid_password`(P0001).
2. `phone_verifications` 에 `purpose='password_reset'`, `is_used=true`, 30분 이내 기록 필요 — 없으면 `phone_not_verified`(P0001).
3. 전화번호로 사용자 조회, 없으면 `user_not_found`(P0001).
4. bcrypt 재해싱 + `token_version+1`(모든 액세스토큰 무효화) + 미회수 refresh token 전부 revoke. 사용자 id 반환.

#### `change_password(p_current, p_new) → void` [SD] (anon/auth 호출 가능)
- `app.uid()` 없으면 `not_authenticated`(42501). `app._set_password()` 위임: 새 비번 6자 미만 `weak_password`(P0001), 현재 비번 불일치 `invalid_current`(P0001), bcrypt 갱신.

#### `change_password_svc(p_user, p_current, p_new, p_tv) → void` [SD][svc]
- 서버 컨텍스트용. `p_user` 가 active 이고 `token_version = p_tv` 인지 검증 후 `app._set_password()` 호출. 불일치 시 `not_authenticated`(42501).

#### `change_password_and_rotate(p_user, p_current, p_new, p_tv, p_new_token_hash, p_user_agent?) → integer` [SD][svc]
- 위 검증 + 비번 변경 후: `token_version+1`, 기존 refresh token 전부 revoke, **새 refresh token(해시) 즉시 발급**(30일/절대 90일). 새 token_version 반환. "비번 변경해도 현재 기기 세션은 유지" 흐름.

#### `bump_token_version(p_user) → integer` [SD][svc]
- `token_version+1` 후 반환. 전체 강제 로그아웃 스위치.

#### `session_alive() → boolean` (SECURITY INVOKER)
- `app.uid() is not null`. 클라이언트가 토큰 유효성(만료/버전 불일치/정지)을 가볍게 확인하는 핑.

### 7.2. Refresh Token 회전 (모두 [SD][svc] — 서버만 호출)

`app.refresh_tokens` 테이블(token_hash, family_id, expires_at 30일, absolute_expires_at 90일, revoked_at, replaced_by)을 다룬다.

#### `rt_issue(p_user, p_token_hash, p_user_agent?) → integer`
- 새 refresh token 해시를 새 family 로 INSERT, 사용자의 token_version 반환.

#### `login_issue_refresh(p_user, p_token_hash, p_user_agent?) → integer`
- `rt_issue` 와 동일하되, **이미 살아있는 다른 refresh token 이 있으면** `security_login` 시스템 알림("새 기기에서 로그인되었어요")을 생성. token_version 반환.

#### `rt_rotate(p_old_hash, p_new_hash, p_user_agent?, p_grace_seconds=30) → TABLE(result, user_id, token_version)`
Refresh token 회전(재사용 감지 포함). 반환 `result` 값:
1. 해시 미존재 → `'invalid'`.
2. 사용자 비활성 → family 전체 revoke 후 `'inactive'`.
3. 만료(절대/일반) → `'expired'`.
4. 미회수 토큰이면 원자적으로 revoke 후 같은 family 로 새 토큰 발급, `replaced_by` 연결 → `'rotated'` + token_version.
5. 이미 회수된 토큰이더라도 revoke 후 `p_grace_seconds`(기본 30초) 이내 재시도면 → `'grace'` 로 새 토큰 발급 (동시 요청 경합 허용).
6. grace 초과 재사용 → **토큰 탈취 의심**으로 family 전체 revoke → `'reuse_revoked'`.

#### `rt_revoke_family(p_hash) → void` / `rt_revoke_user(p_user) → void`
- 각각 해당 해시의 family 전체 / 해당 사용자의 전체 refresh token 을 revoke. (로그아웃/전체 로그아웃)

#### `rate_limit_hit(p_key, p_max, p_window_seconds) → boolean` [SD][svc]
- 고정 윈도우 레이트리미터. `key:윈도우번호` 버킷을 upsert 하며 count 증가, `count <= p_max` 이면 true(허용). 2% 확률로 만료 버킷 청소. 서버가 로그인/SMS 등 남용 방지에 사용.

관련 유지보수: `app.cleanup_auth()` — 만료/회수된 refresh token 과 만료 rate_limits 정리(크론용).

### 7.3. 위치·사진 검증 (모두 [SD][svc])

#### `record_location_verification(p_user, p_lat, p_lng, p_accuracy, p_result, p_region_code, p_address, p_fail_reason, p_fail_limit=5, p_block_minutes=60) → void`
동네(위치) 인증 기록. 서버가 GPS 검증 후 호출:
1. `location_verifications` 에 결과 INSERT.
2. `p_result='success'` 면 `users` 에 좌표·region_code·address 저장, `is_location_verified=true`, 실패 카운트/차단 해제.
3. 실패면 `location_verify_fail_count+1`, 실패가 `p_fail_limit`(기본 5회) 도달 시 `location_verify_blocked_until = now()+60분` 차단.

#### `record_photo_verification(...) → uuid`
사진 실존(안티스푸핑) 검증 기록. AI 판정 결과(개/고양이 real/fake 확률, ai_pass, region_matched, 펫 매칭 점수 등)를 `photo_verifications` 에 INSERT 하고 id(=photo_token) 반환. `expires_at = now() + p_ttl_min(기본 15분)` — 토큰은 15분 내 게시글 작성에 소비돼야 한다. `purpose` 는 'post'(게시용) 또는 'reference'(펫 기준사진).

#### `enroll_pet_identity(p_pet, p_species, p_paths, p_urls, p_breed?, p_colors?, p_info_match?) → void`
- 펫 신원 등록(멀티 프레임): 기존 `pet_identity_frames` 삭제 후 URL 배열을 프레임 0..n 으로 재삽입, `pets` 에 `identity_verified=true` + AI 판정 속성(종/품종/색상/정보일치) 기록.

#### `set_pet_ai_reference(p_pet, p_verification) → void`
- `purpose='reference'`, `result='pass'` 이고 해당 펫의 것인 photo_verification 만 허용(아니면 예외 "유효한 기준 사진 검증이 아닙니다"). `pets.ai_ref_image_url/path/verification_id/verified_at` 갱신 — 이후 게시 사진과의 동일 개체 매칭 기준.

### 7.4. 게시글 (Posts)

#### `create_post_verified(p_category, p_title, p_content, p_scheduled_at, p_pet_ids, p_image_url, p_image_mime, p_image_size, p_photo_token?, p_actual_lat?, p_actual_lng?, p_region_code?) → uuid` [SD] (anon/auth EXECUTE)
검증 게시글 생성의 단일 진입점:
1. 미로그인 시 예외.
2. 카테고리가 `walk_together/walk_proxy/care/give_away` 면 `photo_verifications` 에서 토큰 조회 — 없거나 `pet_id` 없으면 "사진 검증 정보가 올바르지 않습니다", 촬영 펫이 `p_pet_ids` 에 없으면 "촬영한 반려동물이 …와 다릅니다" 예외.
3. `set_config('app.photo_token', …, true)` 로 트랜잭션-로컬 GUC 설정 → BEFORE INSERT 트리거 `tg_posts_check_write` 가 이 토큰을 읽어 최종 검증·소비(§8.9).
4. `posts` INSERT(작성자=app.uid(), 실제 좌표/지역 포함) → `post_pets` 벌크 INSERT.
5. 사진이 AI 매칭(`ai_matched`)되었으면 해당 펫의 `pet_match_count+1`.
6. 새 post id 반환. (자유글 `free` 카테고리는 토큰 없이 통과하나, 트리거에서 별도 규칙 적용.)

#### `delete_my_post(p_post) → void` [SD]
- 로그인·존재·본인 소유 3단계 검증(각각 한국어 메시지 예외) 후 `visibility_status='deleted_by_user'` 로 soft delete. (`trg_posts_deleted_at` 이 deleted_at 세팅.)

#### `can_manage_post_applicants(p_post) → boolean` [SD]
- `app.is_post_manager()` 위임 — 클라이언트가 "지원자 관리 버튼" 노출 여부 판단용.

### 7.5. 지역·지도 (Region / Map)

#### `feed_region_codes() → text[]` [SD]
- 내(`app.uid()`) 위치인증이 안 됐거나 좌표/반경이 없으면 **NULL** 반환(=필터 미적용 신호).
- 인증됐으면: `visible` 게시글의 region_code 중, 동 중심점(`dong_centroids`, 없으면 사용자 평균좌표 fallback)이 **내 활동반경(`activity_radius_m`) 이내**인 코드 배열 반환. 피드 지역 필터의 핵심.

#### `posts_by_region(p_min_lng, p_min_lat, p_max_lng, p_max_lat) → TABLE(region_code, post_count, lng, lat, post_ids)` [SD]
- 지도 바운딩박스 안에서 region_code 별로 게시글을 클러스터링(개수 + 대표 좌표 + 최신순 post id 배열). 지도 화면의 동 단위 마커용. 좌표는 동 중심점 또는 사용자 평균좌표.

#### `dong_centroid_seeds() → TABLE(region_code, seed_lng, seed_lat)` [SD]
- `dong_centroids` 에 아직 없는 region_code 에 대해 사용자 평균 좌표를 시드로 반환(최대 100건). 서버 배치가 동 중심점 테이블을 채울 때 사용.

#### `set_activity_radius(p_m) → integer` [SD]
- 로그인 + 동네인증 완료 필수, 5,000~15,000m 범위만 허용(위반 시 한국어 예외). `users.activity_radius_m` 갱신 후 값 반환.

### 7.6. 시설 (Facilities)

#### `facilities_within(p_lng, p_lat, p_radius_m=5000, p_categories?) → TABLE(...)` (INVOKER)
- PostGIS `st_dwithin` 으로 반경 내(최대 5km 로 클램프) 영업중(`is_open`) 시설을 거리순 최대 500건 반환. 카테고리 배열 필터 선택. SECURITY INVOKER — `facilities` 는 전체 공개 SELECT 라 문제 없음.

#### `facilities_search(p_query, p_lng?, p_lat?) → TABLE(...)` (INVOKER)
- 이름 ILIKE 검색, 좌표를 주면 거리 계산·거리순, 최대 30건.

#### `facility_all_categories(p_id) → text[]` [SD]
- 같은 이름+주소로 등록된 시설 행들의 카테고리 집합 반환(한 장소가 병원+미용 등 복수 카테고리로 중복 등록된 경우 통합 표시용).

#### `ensure_naver_facility(p_name, p_address, p_phone, p_lng, p_lat) → uuid` [SD]
- 로그인 필수. 네이버 검색 결과 장소를 내부 시설로 upsert. `ext_id = md5(lower(공백제거(이름|주소)))` 결정적 키, `source='naver'`, 카테고리 'pet_cafe' 고정으로 INSERT(충돌 시 이름만 갱신). 시설 id 반환 — 외부 장소에도 리뷰를 달 수 있게 하는 장치.

#### `naver_facility_id(p_name, p_address) → uuid` [SD]
- 위 결정적 ext_id 로 기존 매핑 조회(없으면 NULL).

#### `add_facility_review(p_facility, p_rating, p_body, p_paths?, p_urls?) → uuid` [SD]
- 로그인 필수, 평점 1~5 검증. `(facility_id, user_id)` 유니크로 **1인 1리뷰 upsert**(재작성 시 내용 갱신 + `visibility_status='visible'` 복구). 트리거가 시설 평균평점/리뷰수 재계산.

#### `delete_facility_review(p_facility) → void` [SD]
- 내 리뷰를 `visibility_status='deleted_by_user'` 로 soft delete.

#### `facility_reviews_of(p_facility, p_limit=20, p_offset=0) → TABLE(..., is_mine)` [SD]
- visible 리뷰를 최신순 페이지네이션(최대 50), 작성자 닉네임(public_profiles)과 `is_mine`(내 리뷰 여부) 포함.

### 7.7. 채팅·디바이스

#### `start_direct_chat(p_other) → uuid` [SD] (**authenticated 전용** EXECUTE)
1. 로그인/자기자신 금지/상대 active 검증(각 P0001: `not_authenticated`, `invalid_target`, `user_not_found`).
2. `canonical_key = 'direct:작은uuid:큰uuid'` 로 방을 결정적으로 찾거나 생성(`on conflict do nothing` + 재조회로 경쟁 안전).
3. 두 사용자의 멤버십 누락분 보강 후 room id 반환. 1:1 방 중복 생성 불가 보장.

#### `register_device_token(p_token, p_platform, p_device_name?) → void` [SD] (**authenticated 전용**)
- 로그인 필수, 토큰 10자 미만 거부(`invalid_token` P0001). `device_tokens` 를 token 유니크로 upsert — **다른 계정이 쓰던 토큰이면 현 사용자로 소유권 이전**, `is_active=true`, failure_count 리셋.

### 7.8. 푸시 알림 파이프라인 (모두 [SD][svc])

흐름: `notifications` INSERT → `trg_notifications_push`(AFTER INSERT, `app.on_notification_push`) 가 `app.push_config` 의 Edge Function URL 로 `net.http_post` 웹훅 발사 → Edge Function 이 `push_dispatch_batch` 호출 → FCM 발송 → `push_report` 로 결과 보고.

#### `_push_pref_allows(p_user, p_type) → boolean`
- `notification_preferences` 에서 알림 유형별 수신 여부 조회(행 없으면 true).

#### `push_dispatch_batch(p_only_id?, p_limit=50) → TABLE(notification_id, ntype, title, body, resource_type, resource_id, tokens)`
1. 5분 넘게 `sending` 에 머문 건을 `pending` 으로 복구(스턱 회복).
2. `pending` 알림을 `FOR UPDATE SKIP LOCKED` 로 배치 선점.
3. 무음(`is_silent`) → `skipped('silent')`, 수신 설정 꺼짐 → `skipped('pref_off')`, 활성 디바이스 토큰 없음 → `skipped('no_device')`.
4. 발송 대상은 `sending` 으로 표시하고 (알림 내용 + 토큰 jsonb 배열) 행으로 반환 — Edge Function 이 실제 FCM 호출.

#### `push_report(p_results jsonb) → void`
- 결과 배열 처리: `dead_tokens` 는 `app.deactivate_device_token()` 으로 비활성화, 성공은 `app.mark_push_sent()`, 실패는 `app.mark_push_failed()`(시도 3회 도달 시 `failed`, 아니면 `pending` 재큐잉).

보조(app 스키마): `mark_push_sent/failed/skipped`, `deactivate_device_token`, `reconcile_unread_counts(p_user?)`(채팅/알림 미읽음 캐시를 실측으로 재보정 — 본인 또는 관리자/시스템만).

### 7.9. 관리자 RPC (모두 [SD], EXECUTE 는 public 이지만 **함수 첫 줄에서 `app.is_admin()` 아니면 42501 `forbidden`**)

- `admin_dashboard_stats() → json` — 사용자수/정지수/게시글수(미삭제)/예정 약속수/미처리 신고수.
- `admin_list_users(p_search?, p_limit=50, p_offset=0)` — username/nickname/phone ILIKE 검색, 최신순. **username·phone 을 볼 수 있는 유일한 통로**(SECURITY DEFINER 이므로 컬럼 권한 우회).
- `admin_set_user_status(p_user, p_status)` — active/inactive/suspended 만 허용, 자기 자신·타 admin 변경 금지(P0001: `invalid_status`/`cannot_modify_self`/`user_not_found`/`cannot_modify_admin`). 변경 후 `admin_logs` 기록. (`suspended` 전이는 `trg_users_owner_succession` 으로 펫 소유권 승계 유발.)
- `admin_list_posts(p_search?, ...)` — 제목/본문 검색, content 는 140자 절단.
- `admin_set_post_visibility(p_post, p_visibility)` — visible/hidden_by_admin/deleted_by_admin 만 허용, deleted_* 이면 deleted_at 세팅, admin_logs 는 `trg_audit_posts` 가 기록.
- `admin_list_comments(p_post)` — 삭제 포함 전체 댓글.
- `admin_set_comment_deleted(p_comment, p_deleted)` — 댓글 soft delete/복구(카운트는 `trg_comments_count` 가 보정, 감사로그는 `trg_audit_comments`).
- `admin_set_chat_message_deleted(p_message, p_deleted)` — 채팅 메시지 삭제/복구 + admin_logs 직접 기록.
- `admin_list_reports(p_status='open', ...)` — 'open'=submitted+reviewing 묶음 조회.
- `admin_set_report_status(p_report, p_status)` — submitted/reviewing/resolved/dismissed 만, reviewed_by/at 기록 + admin_logs.
- `admin_get_report_target(p_report) → json` — 신고 대상(post/comment/user/chat_message)의 실제 내용 스냅샷 반환, 대상 소실 시 `{kind, exists:false}`.
- `admin_list_inquiries()` — 고객센터(admin_inquiry) 방 목록 + 문의자 + 마지막 메시지.
- `admin_join_inquiry(p_room)` — admin_inquiry 방인지 검증(P0001 `not_inquiry_room`) 후 관리자를 멤버로 추가.
- `admin_list_logs(p_limit=100, p_offset=0)` — 감사 로그 조회(최대 200).

### 7.10. 기타

#### `rls_auto_enable() → event_trigger` [SD]
- DDL 이벤트 트리거 함수: public 스키마에 `CREATE TABLE` 류가 실행되면 **자동으로 해당 테이블 RLS 를 활성화**. "RLS 켜는 걸 잊는" 실수 방지 가드레일.

---

## 8. 트리거

public 테이블에 **52개 트리거**(정의 함수는 모두 `app` 스키마, 39개 트리거 함수)가 걸려 있다. 공통 트리거 `trg_*_updated`(BEFORE UPDATE, `app.tg_set_updated_at`)는 applications, appointments, business_profiles, chat_messages, chat_room_members, device_tokens, notification_preferences, notifications, pets, posts, reports, review_category_counts, users 13개 테이블에서 `updated_at := now()` 를 자동 세팅한다. 나머지를 테이블별로 설명한다.

### 8.1. `applications` (지원)

| 트리거 | 시점 | 함수 | 동작 |
|---|---|---|---|
| `trg_applications_block_insert` | BEFORE INSERT | `tg_applications_block_insert` | 지원 가능성 종합 검증 |
| `trg_applications_immutable_offer` | BEFORE UPDATE | `tg_applications_immutable_offer` | `offered_pet_id` 변경 금지 |
| `trg_applications_on_accept` | AFTER UPDATE | `tg_applications_on_accept` | 수락 시 매칭 확정 처리 |
| `trg_notify_application` | AFTER INSERT | `tg_notify_application` | 글 작성자에게 `post_application` 알림 |
| `trg_notify_application_accepted` | AFTER UPDATE | `tg_notify_application_accepted` | 수락 시 지원자에게 `application_accepted` 알림 |

- **block_insert 검증 순서**: ① 게시글 존재 ② 본인 글 지원 금지 ③ 삭제글 금지 ④ `progress_status='recruiting'` 아닐 때 금지 ⑤ `free` 카테고리 금지 ⑥ 지원자가 그 글에 붙은 펫의 보호자면 금지 ⑦ 글에 비활성 펫 포함 시 금지 ⑧ **adoption(입양) 글**이면 `offered_pet_id` 필수 + 그 펫이 존재·active·지원자가 owner 여야 함, 그 외 카테고리는 `offered_pet_id` 금지. 모든 위반은 한국어 메시지의 P0001 예외.
- **on_accept (pending→accepted 전이 시에만)**:
  1. 게시글 행 잠금(FOR UPDATE).
  2. 관련 펫(post_pets ∪ offered_pet)이 다른 `scheduled` 약속에 물려 있으면 예외("이미 다른 약속이 진행 중").
  3. `posts.progress_status` 를 `recruiting→matched` 로 조건부 UPDATE — 실패하면 "다른 사용자가 먼저 수락하였습니다"(동시 수락 방지).
  4. `appointments` 생성 — 보호자 측 당사자는 **실제 수락한 사람**(작성자이거나 글 펫의 공동보호자면 그 사람, 아니면 작성자로 fallback).
  5. 나머지 pending 지원 일괄 `rejected`.
  6. 공동보호자가 대신 수락했다면 작성자에게 `application_accepted_by_co` 알림(실패 무시).

### 8.2. `appointments` (약속)

| 트리거 | 시점 | 함수 | 동작 |
|---|---|---|---|
| `trg_appointments_pet_busy` | BEFORE INSERT | `tg_appointments_pet_busy_check` | 같은 펫의 중복 scheduled 약속 차단 |
| `trg_appointments_before_update` | BEFORE UPDATE | `tg_appointments_before_update` | 상태 전이 검증: `scheduled → completed|cancelled` 만 허용, terminal 상태 변경 금지, completed 시 `completed_at` 자동 세팅 |
| `trg_appointments_after_update` | AFTER UPDATE | `tg_appointments_after_update` | 완료/취소 후속 처리 |

- **after_update**:
  - `scheduled→completed`: 게시글 `matched→completed`, application `accepted→completed`. 카테고리가 **give_away(분양)** 면 글의 펫 보호자 전원 삭제 후 지원자를 owner 로 등록 + `primary_guardian_id` 이전. **adoption(입양)** 이면 `offered_pet` 을 글 작성자에게 동일 방식으로 이전. → **소유권 이전이 DB 에서 원자적으로 일어남**.
  - `scheduled→cancelled`: 게시글 `matched→recruiting` 복귀, application `accepted→cancelled`.

### 8.3. `chat_messages` / `chat_room_members`

- `trg_chat_messages_after_insert` (AFTER INSERT): 미리보기(`content` 100자 또는 '[사진]')로 방의 `last_message_*` 갱신 → 발신자 제외 멤버들의 `users.unread_chat_count+1` → 멤버별 `chat_message` 알림 INSERT(제목=발신자 닉네임, 본문=미리보기) — 이 알림 INSERT 가 다시 푸시 웹훅을 유발.
- `trg_chat_messages_soft_delete_ts` (BEFORE UPDATE): `is_deleted` false→true 시 `deleted_at := now()`.
- `trg_chat_messages_after_softdelete` (AFTER UPDATE): 삭제된 메시지가 방의 마지막 메시지면 미리보기를 "삭제된 메시지입니다." 로 교체.
- `trg_chat_members_read` (BEFORE UPDATE, chat_room_members): `last_read_message_id` 변경 시 ① 그 메시지가 **같은 방** 메시지인지 검증(아니면 예외) ② (old, new] 구간의 상대 발신·미삭제 메시지 수만큼 `users.unread_chat_count` 를 감산(음수 방지). `(created_at, id)` 튜플 비교로 동시각 메시지도 정확히 처리.

### 8.4. `comments`

- `trg_comments_count` (AFTER INSERT/UPDATE): INSERT 시 `posts.comment_count+1`(미삭제일 때), soft delete 전환 시 -1, 복원 시 +1.
- `trg_comments_soft_delete_ts` (BEFORE UPDATE): 삭제 전환 시 `deleted_at` 세팅.
- `trg_notify_comment` (AFTER INSERT): 글 작성자에게 `post_comment` 알림(본인 댓글 제외, 실패 무시).
- `trg_audit_comments` (AFTER UPDATE): **관리자가** 삭제로 전환한 경우에만 `admin_logs` 에 `delete_comment` 기록.

### 8.5. `posts`

- `trg_posts_check_write` (BEFORE INSERT, `tg_posts_check_write`) — **게시글 작성 자격의 최종 관문**:
  1. 작성자 존재 검증.
  2. `walk_together/walk_proxy/care/give_away` 는 `user_type='pet_owner'` 만.
  3. give_away 는 본인이 owner 인 active 펫 보유 필수; walk/care 는 보호 중인 active 펫 보유 필수.
  4. walk/care 는 `scheduled_at` 필수, give_away/adoption 은 `scheduled_at` 금지.
  5. 사진 필요 카테고리는 `image_url` 필수 + GUC `app.photo_token` 필수. `photo_verifications` 에서 (본인·purpose='post'·pet 지정·result='pass'·ai_pass·region_matched·미소비·미만료·**image_url 일치**) 조건으로 조회 — 실패 시 "유효하지 않거나 만료된 사진 검증입니다".
  6. 통과 시 토큰 `consumed_at` 소비(1회용), `photo_verification_id`/`ai_pet_species`/`is_pet_verified` 를 게시글에 스탬프.
- `trg_posts_set_region` (BEFORE INSERT): region_code 미지정 시 작성자의 region_code 복사, `display_address` 미지정 시 작성자 주소의 **마지막 토큰(동 이름)** 만 노출용으로 저장.
- `trg_posts_deleted_at` (BEFORE INSERT/UPDATE): `visibility_status like 'deleted_%'` 면 deleted_at 세팅, 아니면 NULL 로 클리어.
- `trg_posts_validate_transition` (BEFORE UPDATE): 상태기계 강제 — visibility: `visible→hidden_by_user|hidden_by_admin|deleted_by_user|deleted_by_admin`, `hidden_by_user→visible|deleted_by_user`, `hidden_by_admin→visible|deleted_by_admin`, deleted_* 는 terminal. progress: `recruiting→matched|cancelled`, `matched→completed|recruiting`, completed/cancelled 는 terminal. 위반 시 예외.
- `trg_audit_posts` (AFTER UPDATE): 관리자가 hidden_by_admin/deleted_by_admin 으로 바꿀 때 `admin_logs`(hide_post/delete_post) 기록.

### 8.6. `post_hearts` / `post_views` / `post_pets`

- `trg_post_hearts_count` (AFTER INSERT/DELETE): `posts.heart_count` ±1 (음수 방지).
- `trg_post_views_count` (AFTER INSERT): `posts.view_count+1`.
- `trg_post_pets_giveaway_limit` (BEFORE INSERT): 글 작성자가 그 펫의 보호자가 아니면 차단("본인이 보호 중인 반려동물만 연결 가능"); give_away 글은 **owner 역할 + 정확히 1마리**만 연결 가능.

### 8.7. `pets` / `pet_guardians` / `pet_guardian_invites`

- `trg_pets_after_insert`: 펫 등록 시 `primary_guardian_id` 를 owner 보호자로 자동 등록 + 등록자 `user_type` 을 `pet_owner` 로 자동 승격.
- `trg_pet_guardians_owner_self_remove` (BEFORE DELETE): 사용자 컨텍스트(`app.uid()` 존재)에서 owner 본인 행 직접 삭제 금지("먼저 소유권을 이전하세요") — 시스템(분양 이전)은 우회 가능.
- `trg_pgi_resolve_invitee` (BEFORE INSERT, invites): `invitee_user_id` 가 없고 전화번호만 있으면 가입자 조회해 자동 연결.
- `trg_notify_guardian_invite` (AFTER INSERT): `kind='invite'` 이고 수신자 확정 시 `guardian_invite` 알림("OO님이 △△의 공동보호자로 초대했어요").
- `trg_pgi_respond` (BEFORE UPDATE): `pending→accepted` 시 — invite 면 초대받은 사람이, request 면 신청자가 보호자가 됨(미확정이면 예외). **그 사람이 해당 펫 글의 진행 중 약속 지원자면 수락 차단**(이해충돌 방지). `pet_guardians` 에 `co_guardian` 으로 INSERT(중복 무시), `responded_at` 세팅. `declined/expired` 도 responded_at 기록.

### 8.8. `users`

- `trg_users_after_insert`: ① `notification_preferences` 기본행 ② admin 이 아니면 고객센터(`admin_inquiry`) 채팅방 + 본인 멤버십 자동 생성(`canonical_key='admin_<uid>'`) ③ 내 전화번호로 걸려 있던 pending 보호자 초대에 `invitee_user_id` 연결 + 초대 알림 생성.
- `trg_users_owner_succession` (AFTER UPDATE): `active → inactive|suspended` 전이 시 **펫 소유권 승계** — owner 인 각 펫에 대해 가장 오래된 co_guardian 을 owner 로 승격(+`primary_guardian_id` 갱신); 후계자가 없으면 펫을 `deleted` 처리. 마지막에 떠나는 사용자의 보호자 행 전부 삭제. (self-remove 방지 트리거와의 충돌을 피하려고 먼저 co_guardian 으로 강등하는 순서 제어 포함.)

### 8.9. `reviews` / `review_category_counts` / `facility_reviews` / `notifications` / `reports` 등

- `trg_reviews_validate` (BEFORE INSERT): 약속 존재 + `status='completed'` 필수, reviewer/reviewee 가 정확히 약속 당사자 쌍(양방향)이어야 함, categories 배열 중복 금지.
- `trg_reviews_aggregate` (AFTER INSERT): 카테고리별로 `review_category_counts` upsert(+1) — 프로필의 "받은 평가" 집계.
- `trg_notify_review` (AFTER INSERT): 상대에게 `review_received` 알림.
- `facility_reviews_aggs` (AFTER INSERT/UPDATE/DELETE): `app.refresh_facility_aggs()` 로 시설의 `review_count`/`avg_rating`(소수1자리) 재계산.
- `trg_notifications_push` (AFTER INSERT, `app.on_notification_push`): `push_status='pending'` 이고 무음이 아니면 `app.push_config` 의 URL 로 `net.http_post`(헤더 `x-push-secret`) — Edge Function 즉시 기동.
- `trg_notifications_read_ts` (BEFORE UPDATE): 읽음 전환 시 `read_at` 세팅.
- `trg_notifications_unread_count` (AFTER INSERT/UPDATE): `users.unread_notification_count` 증감 캐시 유지.
- `trg_audit_reports` (AFTER UPDATE): 관리자의 신고 상태 변경을 `admin_logs`(update_report_status, before/after) 기록.

또한 DB 수준 **이벤트 트리거**로 `rls_auto_enable`(§7.10)이 걸려 있어 public 에 새 테이블이 생기면 RLS 가 자동 활성화된다.

---

## 9. RLS 정책

public 스키마 **73개** + storage **3개** = 총 76개 정책. 전부 PERMISSIVE, 대상 롤은 public(storage 는 authenticated). 판별은 전적으로 `app.uid()` / `app.is_admin()` / `app.is_*` 헬퍼에 의존하므로 **JWT 없이(anon) 접근하면 `app.uid()=NULL` 이 되어 "내 것" 조건이 모두 false** 가 된다.

### 테이블별 요약

| 테이블 | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `admin_logs` | 관리자만 | — | — | — |
| `applications` | 지원자 본인 또는 글 관리자(`is_post_manager`) | 본인 명의만(`applicant_id=uid`) | 지원자 본인 또는 글 관리자 | — |
| `appointments` | 당사자(글 소유측/지원자) 또는 관리자 | — (트리거가 생성) | 당사자 또는 관리자 (WITH CHECK 동일) | — |
| `business_profiles` | 전체 공개 | 본인 또는 관리자 | 본인 또는 관리자 | — |
| `chat_message_deletions` | 본인 것만 | 본인 명의만 | — | — |
| `chat_messages` | 방 멤버 또는 관리자 | 본인 발신 + 방 멤버일 때만 | **관리자만** (일반 사용자는 메시지 수정/삭제 불가 — 관리자 RPC 로만 soft delete) | — |
| `chat_room_members` | 본인 행, 같은 방 멤버, 관리자 | 본인 등록 또는 관리자 | 본인 행만(읽음 포인터 갱신용) | — |
| `chat_rooms` | 방 멤버 또는 관리자 | 로그인 사용자 누구나(`uid is not null`) | 관리자만 | — |
| `comments` | 미삭제 댓글 전체 또는 관리자(삭제 포함) | 본인 명의만 | 본인 또는 관리자 | — |
| `device_tokens` | ALL: 본인 것만 (SELECT/INSERT/UPDATE/DELETE 일괄) | | | |
| `facilities` | 전체 공개 | — | — | — |
| `facility_cache` | 전체 공개 | 관리자 | 관리자 | 관리자 |
| `facility_reviews` | visible 리뷰 전체 + 본인 리뷰(숨김 포함) | — (RPC 전용) | — | — |
| `location_verifications` | 본인 또는 관리자 | 본인 명의만 (실제로는 svc RPC 사용) | — | — |
| `notification_preferences` | ALL: 본인 것만 | | | |
| `notifications` | 본인 또는 관리자 | **관리자만** (일반 알림은 트리거/SECURITY DEFINER 가 생성) | 본인 또는 관리자(읽음 처리) | — |
| `pawings` | 전체 공개(팔로우 관계는 공개 정보) | 본인이 follower 일 때만 | — | 본인이 follower 일 때만(언팔) |
| `pet_guardian_invites` | 초대자/피초대자/펫 owner/관리자 | 초대자 본인 + (invite 는 owner 만, request 는 누구나) | 관리자, invite 는 피초대자, request 는 펫 owner (응답 권한) | — |
| `pet_guardians` | 그 펫의 보호자(아무 역할) 또는 관리자 | 펫 owner 또는 관리자 | 펫 owner 또는 관리자 | 펫 owner 또는 관리자 |
| `pet_identity_frames` | 그 펫의 보호자 또는 관리자만 (신원 프레임은 비공개) | — | — | — |
| `pets` | `pet_status<>'deleted'` 전체 공개 + 삭제펫은 보호자/관리자만 | `primary_guardian_id=uid` 본인 명의만 | 펫 owner 또는 관리자 | — |
| `post_hearts` | 전체 공개 | 본인 명의만 | — | 본인 것만(하트 취소) |
| `post_pets` | 글이 visible 이거나 글 작성자/관리자 | 글 작성자만 | — | 글 작성자 또는 관리자 |
| `post_views` | 관리자만 | 본인 명의만(조회 기록) | — | — |
| `posts` | visible 전체 + hidden_by_user 는 작성자만 + 관리자 전부 | 본인 명의만 | 본인 또는 관리자 | **관리자만**(하드 삭제) |
| `reports` | 신고자 본인 또는 관리자 | 본인 명의만 | 관리자만 | — |
| `review_category_counts` | 전체 공개 | — (트리거가 관리) | — | — |
| `reviews` | 전체 공개 | reviewer 본인만(+ 트리거 검증) | — | — |
| `user_blocks` | 차단한 본인만 | 본인 명의만 | — | 본인 것만(차단 해제) |
| `users` | `status<>'suspended'` 전체 + 본인 + 관리자 (정지 계정은 타인에게 숨김) | — (가입은 signup_user RPC) | 본인 또는 관리자 (단, 컬럼 권한으로 갱신 가능 컬럼 제한 — §10) | — |

설계 특징:
- **삭제는 대부분 soft delete**: comments/chat_messages/posts/facility_reviews 는 DELETE 정책이 없거나 관리자 전용이고, `is_deleted`/`visibility_status` 갱신으로 처리한다.
- **정지 계정 처리**: `users_select` 가 suspended 를 숨기고, `app.uid()` 자체가 active 만 인정하므로 정지 즉시 모든 권한이 소멸한다.
- INSERT 가 막힌 테이블(appointments, notifications, facility_reviews 등)은 SECURITY DEFINER RPC/트리거만 쓸 수 있다.

### storage.objects 정책 (버킷 `media`)

| 정책 | 대상 | 내용 |
|---|---|---|
| `media owner insert` | authenticated INSERT | `bucket_id='media'` 이고 **경로 첫 폴더명 = 본인 uid** 일 때만 업로드 (`storage.foldername(name)[1] = app.uid()::text`) |
| `media owner update` | authenticated UPDATE | 동일 조건 — 자기 폴더 안 객체만 |
| `media owner delete` | authenticated DELETE | 동일 조건 — 자기 폴더 안 객체만 |

즉 파일 경로 규약은 `media/<user_id>/...` 이고, 쓰기·수정·삭제는 자기 폴더로 한정된다. SELECT 정책은 없다(공개 버킷이라 public URL 로 읽음, §11).

---

## 10. 컬럼 권한 및 함수 실행 권한

### 10.1. users 테이블 — 컬럼 단위 SELECT/UPDATE (핵심 프라이버시 장치)

`users` 는 **테이블 수준 SELECT/UPDATE/INSERT 권한이 회수**되어 있고(authenticated 에는 REFERENCES/TRIGGER/TRUNCATE 만 잔존), 필요한 컬럼에만 컬럼 단위 GRANT 가 있다. 이로써 RLS 로는 막을 수 없는 **컬럼 숨김**을 구현했다.

| 권한 | anon | authenticated |
|---|---|---|
| SELECT | id, nickname, user_type, profile_image_url, profile_image_thumbnail_url, address, is_location_verified, created_at | 왼쪽 + last_verified_at |
| UPDATE | — | nickname, profile_image_url, profile_image_thumbnail_url, profile_image_mime_type, profile_image_file_size, push_enabled |

- **`username`(로그인 ID), `phone`, `password_hash`, `latitude`/`longitude`(정확 좌표), `token_version`, `status`, `region_code`, 미읽음 카운트 등은 SELECT 불가.** → username 은 관리자 RPC(`admin_list_users`)와 SECURITY DEFINER 함수 내부에서만 접근된다. **검증 완료: username 은 컬럼 GRANT 로 숨겨져 있음.**
- 일반 사용자가 UPDATE 할 수 있는 것도 닉네임/프로필 이미지/푸시 on-off 뿐 — user_type, status, is_location_verified 등은 클라이언트가 직접 조작 불가(RPC/트리거 전용).

### 10.2. posts / pets — 컬럼 단위 권한

`posts` 도 테이블 수준 SELECT/INSERT/UPDATE 가 없고 컬럼 GRANT 로 제한된다:

- **SELECT (anon/authenticated 동일)**: id, category, title, content, user_id, 각종 image_*, scheduled_at, display_address, display_lat, display_lng, is_location_hidden, location_radius_m, region_code, heart/comment/view_count, progress_status, visibility_status, created/updated/deleted_at.
  → **`actual_lat`/`actual_lng`(실제 좌표), `photo_verification_id`, `ai_pet_species`, `is_pet_verified` 는 조회 불가.** 위치는 display_* 만 공개.
- **INSERT (authenticated)**: category, title, content, scheduled_at, image_*, user_id 만 — 좌표/지역/검증 필드는 직접 넣을 수 없고 `create_post_verified` RPC + 트리거가 채운다.
- **UPDATE (authenticated)**: 다수 컬럼 허용(진행/가시성 상태 포함 — 단 상태 전이는 트리거가 검증).

`pets`:
- **SELECT**: 전체 프로필·AI 판정 컬럼 공개(anon 포함).
- **INSERT (authenticated)**: 기본 프로필 컬럼 + primary_guardian_id 만 — `identity_verified`, `ai_*`, `pet_match_count` 등은 직접 설정 불가.
- **UPDATE (authenticated)**: 프로필 컬럼 + pet_status 만.

기타: `dong_centroids`, `facilities`, `facility_reviews`, `pet_identity_frames`, `photo_verifications`, `public_profiles` 및 모든 뷰는 anon/authenticated 에 **SELECT 만** 부여(쓰기는 RPC/서버 전용). 나머지 일반 테이블은 테이블 수준 풀 권한 + RLS 로 통제. (`spatial_ref_sys`, `geometry_columns` 등 PostGIS 시스템 객체는 기본 그랜트 그대로.)

### 10.3. 함수 EXECUTE 권한 (proacl 기준)

**service_role 전용 (anon/authenticated EXECUTE 없음— 서버/Edge Function 만 호출 가능):**

`_push_pref_allows`, `bump_token_version`, `change_password_and_rotate`, `change_password_svc`, `enroll_pet_identity`, `login_issue_refresh`, `push_dispatch_batch`, `push_report`, `rate_limit_hit`, `record_location_verification`, `record_photo_verification`, `reset_password_user`, `rt_issue`, `rt_revoke_family`, `rt_revoke_user`, `rt_rotate`, `set_pet_ai_reference`, `signup_user` — **18개**. 토큰 발급/회전, 가입, 비밀번호 재설정, 검증 기록, 푸시 파이프라인 등 신뢰 경계 밖에 노출하면 안 되는 함수가 전부 잠겨 있다.

**authenticated + service_role (anon 불가):** `register_device_token`, `start_direct_chat`.

**anon 포함 호출 가능:** `login_user`, `check_username_available`(로그인 전 필요) 및 나머지 일반 RPC(admin_* 포함). 단 `admin_*` 계열은 함수 본문 첫 줄의 `app.is_admin()` 체크로 42501 을 던지므로 실질적으로 관리자 전용이다. `app` 스키마 함수들은 클라이언트 롤에 스키마 USAGE 가 없어 직접 호출 경로가 없다.

---

## 11. Storage

### 버킷

| id | public | file_size_limit | allowed_mime_types |
|---|---|---|---|
| `media` | **true (공개)** | 제한 없음(NULL) | 제한 없음(NULL) |

- 버킷은 하나(`media`)뿐이며 **공개 버킷**이다 — 업로드된 객체는 public URL 로 누구나 읽을 수 있다(프로필/게시글/채팅 이미지, 시설 리뷰 사진, 펫 신원 프레임 등).
- 쓰기 통제는 §9 의 storage.objects 정책 3개: 경로 규약 `media/<user_id>/...` 아래에서만 본인(authenticated + `app.uid()`)이 INSERT/UPDATE/DELETE 가능. anon 은 업로드 불가.
- 참고: 파일 크기·MIME 제한이 버킷 레벨에 없으므로 검증은 앱/서버 계층 책임이다. 또한 공개 버킷 특성상 URL 을 아는 누구나 원본(예: 사진 검증 원본, 펫 신원 프레임)을 볼 수 있다는 점은 운영상 유의 사항.

## 12. Realtime

`supabase_realtime` publication 에 포함된 테이블은 **2개**:

| 테이블 | 용도 |
|---|---|
| `public.chat_messages` | 채팅방 실시간 메시지 수신 (INSERT/UPDATE 구독 — soft delete 반영 포함) |
| `public.notifications` | 인앱 알림 실시간 수신 (새 알림 뱃지/토스트) |

- 두 테이블 모두 전 컬럼이 발행되며 row filter 는 없다 — 수신 범위 제한은 **RLS 로 강제**된다(chat_messages 는 방 멤버만, notifications 는 본인 것만 SELECT 가능하므로 Realtime 도 그 범위만 전달됨).
- 그 외 테이블(posts, comments 등)은 Realtime 발행 대상이 아니다 — 폴링/재조회 방식.

---

### 부록: 오류 코드 관례

- `42501 (insufficient_privilege)`: 인증 실패(`not_authenticated`) 또는 관리자 아님(`forbidden`).
- `P0001 (raise_exception)`: 비즈니스 규칙 위반. 영어 스네이크 코드(`username_taken`, `phone_not_verified`, `invalid_status`, `report_not_found`, `invalid_token` …) 또는 트리거의 한국어 메시지(`'applications: 본인 게시글에는 지원할 수 없습니다'`, `'다른 사용자가 먼저 수락하였습니다'` 등). 클라이언트는 message 프리픽스로 도메인을 식별한다.

---

## 13. 마이그레이션 이력

이 저장소에서 관리하는 마이그레이션 77개 (적용 순서 = 파일명 타임스탬프). 설명은 각 파일의 헤더 주석 첫 줄.
`20260603*` 이전의 기반 스키마는 Supabase 프로젝트에 이미 적용되어 있으며 이 저장소 범위 밖이다.

| 버전 | 파일명 | 내용 |
|---|---|---|
| `20260608044442` | `signup_user_function` | 회원가입: 비밀번호를 pgcrypto(bcrypt)로 해싱해 users INSERT. |
| `20260608051112` | `login_rpc_and_feed_views` | 1) 로그인 검증: username/password 일치 + active 인 사용자만 반환. |
| `20260608071651` | `chat_rooms_view_and_realtime` | 채팅방 목록 뷰: 내가 속한 방 + 상대 닉네임 + 마지막 메시지 + 안 읽은 수. |
| `20260608072435` | `chat_rooms_view_label_admin_v2` | 상대 멤버가 없는 admin_inquiry(고객센터) 방은 '고객센터'로 라벨링. |
| `20260608095600` | `start_direct_chat_and_pawing_views` | 1:1 채팅방 find-or-create. 상대방 멤버십 INSERT 는 RLS(user_id=app.uid())로 막히므로 |
| `20260608150932` | `media_storage_bucket` | 이미지 업로드용 공개 버킷. 경로 규약: <uid>/<category>/<filename> |
| `20260608151755` | `post_feed_add_image_url` | v_post_feed 에 image_url 추가 (컬럼을 끝에 추가 → CREATE OR REPLACE 허용). |
| `20260609051500` | `notification_generation_triggers` | 이벤트 발생 시 notifications 자동 생성. |
| `20260610104641` | `pet_owner_promote_on_pet_register` | 펫 등록(소유자) 시 users.user_type 을 'pet_owner' 로 자동 승격. |
| `20260610112605` | `applications_on_accept_auto_reject_others` | 지원 수락 시 나머지 지원자 자동 거절. |
| `20260610120125` | `username_private_and_dupcheck` | 아이디(username)를 로그인 전용 비공개 값으로 전환 + 가입 시 아이디 중복확인 RPC 추가. |
| `20260611041301` | `coguardian_applicant_manage_helpers` | 공동보호자가 다른 보호자의 게시글 지원자를 관리(조회·수락)할 수 있게 하는 기반. |
| `20260611041321` | `coguardian_applications_rls` | 공동보호자도 지원자 목록 조회 + 수락(상태 변경)이 가능하도록 applications RLS 확장. |
| `20260611041346` | `coguardian_accept_owner_side_and_notify` | 수락 시 생성되는 약속의 보호자 측(post_owner_id)을 "실제 수락한 사람"으로 설정. |
| `20260611041810` | `notifications_allow_accepted_by_co` | 공동보호자 대리 수락 알림 타입(application_accepted_by_co)을 notifications CHECK 허용목록에 추가. |
| `20260611051408` | `block_guardian_accept_while_scheduled_appointment` | 보호자 초대 수락 시점 가드. |
| `20260611051913` | `pgi_resolve_invitee_on_insert` | 초대 발송 시점에 전화번호가 이미 가입된 사용자면 invitee_user_id 를 즉시 연결. |
| `20260611052855` | `notify_guardian_invite` | 공동보호자 초대 시 수신자에게 알림(guardian_invite). |
| `20260611063036` | `admin_dashboard_stats_rpc` | 관리자 대시보드 통계 RPC. app.is_admin() 이 아니면 거부. |
| `20260611063802` | `admin_users_rpcs` | 관리자 회원 관리 RPC (is_admin 게이트). |
| `20260611064132` | `admin_reports_rpcs` | 관리자 신고 처리 RPC (is_admin 게이트). |
| `20260611064528` | `admin_posts_comments_rpcs` | 관리자 게시글/댓글 관리 RPC (is_admin 게이트). |
| `20260611064652` | `admin_posts_comments_dedup_audit` | posts/comments 는 기존 감사 트리거(tg_audit_posts/tg_audit_comments)가 admin_logs 를 남기므로 |
| `20260611065233` | `admin_inquiries_rpcs` | 관리자 문의(admin_inquiry 채팅방) 처리 RPC (is_admin 게이트). |
| `20260611065322` | `admin_inquiries_rpc_fix` | fix: chat_room_members 에 created_at 없음 → lateral 의 order by 제거(문의방 비관리자 멤버 1명). |
| `20260611065354` | `admin_inquiries_rpc_fix2` | fix: last_message_preview(varchar) → text 캐스팅 (반환 타입 일치). |
| `20260611104451` | `chat_rooms_view_inquiry_label` | admin_inquiry 방에서 상대(other)를 "관리자가 아닌 멤버"로 한정. |
| `20260611104952` | `change_password_rpc` | 로그인한 본인의 비밀번호 변경. 현재 비밀번호 확인 후 bcrypt 로 갱신. |
| `20260611110625` | `admin_report_target_and_logs_rpcs` | 신고 대상(게시글/댓글/회원/채팅메시지) 실제 내용 조회 + 채팅메시지 조치 + 감사 로그 조회. |
| `20260619090000` | `users_region_code` | 0017 지역 인증 — 활동 지역 행정동코드 컬럼 추가. |
| `20260619090100` | `users_update_column_grants` | 0017 지역 인증 — users UPDATE 컬럼 권한 정리 (보안). |
| `20260619090200` | `record_location_verification` | 0017 지역 인증 — 인증 결과를 한 트랜잭션으로 반영하는 RPC. |
| `20260622090000` | `reports_dedup_unique` | 신고 중복 방지 — 같은 신고자가 같은 대상에 처리 중(open)인 신고를 중복 생성하지 못하게 한다. |
| `20260626090000` | `photo_verifications` | 게시글 사진 실존 검증(촬영 위치 일치 + AI 반려동물 판별) 로그 및 1회용 토큰 (0018) |
| `20260626090100` | `posts_photo_verification_columns` | posts 검증 결과 요약 컬럼 + INSERT 컬럼 화이트리스트 (0018) |
| `20260626090200` | `record_photo_verification` | 사진 검증 결과 기록 RPC (0018) — 0017 record_location_verification 와 동형. |
| `20260626090300` | `posts_require_photo_token_trigger` | app.tg_posts_check_write 에 사진 실존 검증 토큰 검사 추가 (0018) |
| `20260626090400` | `create_post_verified` | 게시글 작성 RPC (0018) — 사진 검증 토큰을 트랜잭션 로컬로 안전하게 전달. |
| `20260626091000` | `pets_ai_reference_and_trust` | 펫 AI 인증 기준 사진 + 개체 일치 신뢰도 (0019) |
| `20260626091100` | `photo_verifications_pet_match` | photo_verifications 에 펫 개체 대조 정보 추가 (0019) |
| `20260626091200` | `record_photo_verification_v2` | record_photo_verification 재정의 — 펫 개체 대조 인자 추가 (0019) |
| `20260626091300` | `set_pet_ai_reference` | 펫 AI 인증 기준 사진 설정 RPC (0019) |
| `20260626091400` | `posts_pet_match_trigger` | tg_posts_check_write — 개체 대조 토큰 요구 + is_pet_verified=매칭여부 (0019) |
| `20260626091500` | `create_post_verified_v2` | create_post_verified 확장 — 토큰 펫 ↔ 선택 펫 바인딩 + 신뢰도 가산 (0019) |
| `20260626092000` | `delete_my_post` | 작성자 본인 게시글 소프트 삭제 RPC. |
| `20260627090000` | `pets_species_kind` | 펫 종 분류(강아지/고양이) 컬럼. |
| `20260627100000` | `pet_identity_frames` | 펫 신원 기준 프레임 (0020) |
| `20260627100100` | `pets_identity_columns` | pets 신원 인증 컬럼 (0020) |
| `20260627100200` | `enroll_pet_identity_rpc` | 펫 신원 인증 반영 RPC (0020) |
| `20260628100000` | `facilities` | 반려동물 시설 지도 (0021) — 공공데이터(병원/미용/위탁/분양) PostGIS 반경조회. |
| `20260628120000` | `post_region_clusters` | 게시글 행정동 클러스터 (0021 §6) |
| `20260628140000` | `facilities_search` | 시설명 검색 RPC (0021) — 지도 검색창용. 이름 ilike, 좌표 있으면 가까운 순. |
| `20260628160000` | `dong_centroids` | 행정동 중심좌표 (0021 §6 정밀화). 운영 적용 완료(형상 기록). |
| `20260629100000` | `post_author_dong_and_activity_radius` | 게시글 작성자 활동지역(동) 표시 + 사용자 활동 범위 설정 (0021). 운영 적용 완료(형상 기록). |
| `20260629120000` | `feed_activity_range_filter` | 활동범위 기반 게시글 피드 필터 (0021). 운영 적용 완료(형상 기록). |
| `20260629140000` | `post_report_categories` | 게시글 전용 신고 사유 추가 (0021). 운영 적용 완료(형상 기록). |
| `20260629160000` | `feed_author_address` | v_post_feed 에 작성자 현재 주소(author_address) 노출 (0021). 운영 적용 완료(형상 기록). |
| `20260629170000` | `feed_visibility_fix` | 피드 가시성 버그 수정 (0021) |
| `20260629180000` | `facility_reviews` | 시설 후기/사진 (0021) — 시설마다 사용자가 별점·후기·사진 작성. 운영 적용 완료(형상 기록). |
| `20260629200000` | `facility_reviews_0022` | 0022 시설 후기 정비 — 카페 승격 + 평균 캐시 + RPC 전용 쓰기. 운영 적용 완료(형상 기록). |
| `20260630120000` | `advisor_fixes` | Supabase advisor 경고 정리(운영 적용 완료, 형상 기록). |
| `20260630160000` | `security_revoke_view_write_grants` | 보안 수정(CRITICAL): SECURITY DEFINER 뷰를 통한 무인증 권한 상승 차단. 운영 적용 완료(형상 기록). |
| `20260630170000` | `security_revoke_broad_write_grants` | 보안 방어심화(MEDIUM): anon/authenticated 의 불필요한 직접 쓰기 GRANT 회수. 운영 적용 완료(형상 기록). |
| `20260630180000` | `security_active_uid_enforce_status` | 보안(MEDIUM #3): app.uid() 가 status='active' 사용자만 식별하도록 강화. 운영 적용 완료(형상 기록). |
| `20260701090000` | `refresh_tokens_phase1` | Refresh-Token + Session-Version 백엔드 1단계 (설계: docs/refresh-token-flow-design.md) |
| `20260701100000` | `auth_phase1_hardening` | refresh-token 1단계 하드닝 (리뷰 반영): |
| `20260701110000` | `rate_limit_opportunistic_cleanup` | 레이트리밋 리뷰 반영(A): app.rate_limits 무한 증가 방지. |
| `20260701120000` | `reset_password_user` | 비밀번호 재설정: 전화 OTP(password_reset) 인증 완료(30분 내)된 번호로 사용자 찾아 비번 갱신. |
| `20260701130000` | `session_alive` | 세션 유효성 확인 RPC: 현재 JWT 가 활성 사용자 + token_version 일치로 app.uid 를 해석하면 true. |
| `20260701140000` | `change_password_atomic` | change-password 원자화(리뷰 minor #1): 엣지가 4개 RPC(change_password_svc/bump_token_version/ |
| `20260701150000` | `pg_cron_auth_cleanup` | pg_cron 정리잡: app.refresh_tokens(만료·오래된 회수) + app.rate_limits(만료) 주기 삭제. |
| `20260701160000` | `new_device_login_notice` | 새 기기 로그인 인앱 알림: 다른 활성 세션이 있는 상태로 새 기기가 로그인하면 |
| `20260701170000` | `push_delivery_core` | 푸시 발송 파이프라인(사장님 스캐폴딩 완성): device_tokens/notification_preferences/ |
| `20260701170500` | `push_delivery_triggers` | 푸시 발송 트리거링: (1) notifications insert 시 즉시 pg_net 으로 send-push 호출(단건, 저지연), |
| `20260701180000` | `chat_message_notifications` | 채팅 푸시: 채팅 메시지 insert 시 수신자(발신자 제외 룸 멤버)에게 'chat_message' 알림 생성. |
| `20260702120000` | `facility_all_categories` | 같은 업체(이름+주소 동일)의 전체 카테고리 조회 RPC — 시설 상세용. |
| `20260702130000` | `drop_dup_device_token_index` | device_tokens.token 중복 유니크 인덱스(`device_tokens_token_uq`) 제거 — `device_tokens_token_key`만 유지. |
