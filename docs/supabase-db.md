# PawMate Supabase — DB 구조 및 로직 문서

- **프로젝트**: `vyatppuxmpulqtxevfpk` (PAWMATE, region `ap-northeast-2`, Postgres 17)
- **조사일**: 2026-07-02 최초 작성 · **2026-08-04 갱신** — 라이브 DB를 직접 조회해 작성 (마이그레이션 파일이 아닌 실제 배포 상태 기준)
- **2026-08-04 갱신 범위**: 개요 수치·테이블 그룹, `app` 스키마 테이블 7개와 `public.business_match_rules` 신설분, 뷰 1개 추가, 마이그레이션 이력 전량(77 → 191), 그리고 **`app.uid()` 의 판정 조건 변경**(아래). 개별 테이블 상세 중 07-02 이후 컬럼이 늘어난 것들은 컬럼 표까지 다시 훑지 못했으므로, 정확한 현재 정의는 `supabase/schema/schema.sql`(스냅샷)이 정본이다
- **짝 문서**: [supabase-api.md](supabase-api.md) — Edge Functions(API 계층) 레퍼런스
- **구성**: §1–5 스키마(ENUM/테이블/제약/인덱스), §6–12 로직(뷰/RPC/트리거/RLS/권한/Storage/Realtime), §13 마이그레이션 이력

## 인증/신원 판별 공통 기반 (`app` 스키마)

> 이 프로젝트는 Supabase Auth 를 사용하지 않는 **자체 JWT 인증** 구조다.
> 핵심 축은 `app` 스키마의 헬퍼 함수들이다:
> - `app.uid()` — PostgREST 가 주입한 `request.jwt.claims` 의 `sub`(사용자 id)와 `tv`(token_version)를 읽어, **활성(active) 상태이고 token_version 이 일치하며 `lite` 클레임이 없는** 사용자의 uuid 를 반환. 불일치/비활성/무토큰이면 NULL. 모든 RLS·뷰·RPC 의 신원 판별 기준.
>   - **`lite` 클레임 조건은 2026-08-04 추가**(0032 §1.1). `signup-lite` 가 발급하는 간이 후기 토큰을 거른다 — 그 전에는 **기존 정식 회원이 간이 경로로 들어오면 `status='active'` 라 완전 세션이 나갔다.** 판정 근거를 계정 상태에서 토큰으로 옮긴 것이고, 텍스트 비교(`<> 'true'`)인 이유는 캐스팅 오류가 RLS 안에서 터지면 '거부' 가 아니라 '쿼리 실패' 가 되기 때문.
> - `app.uid_lite()` — 위와 같되 `status in ('active','lite')` 를 허용하고 `lite` 클레임을 막지 않는다. **간이 후기 3종 전용**(`add_facility_review` · `facility_review_by_id` · `facility_reviews_of`).
> - `app.is_admin()` — `app.uid()` 사용자가 `user_type='admin'` 이고 `status='active'` 인지.
> - `app.is_pet_guardian(pet, role?)` — 해당 펫의 보호자(역할 지정 가능: 'owner'/'co_guardian') 여부.
> - `app.is_post_manager(post)` — 게시글 작성자이거나, 게시글에 연결된 펫의 보호자이거나, 관리자.
> - `app.is_room_member(room)` — 채팅방 멤버 여부.
> - `app.is_blocked_pair(a, b)` — 두 사용자가 **방향 무관** 차단 관계인가(2026-08-04 신설, 0032 §2). 차단 여부를 묻는 **술어**. 종전에는 같은 조건이 뷰 3개와 트리거에 흩어져 있었고, 그게 알림·팔로우 경로가 누락된 원인이었다.
- `app.blocked_ids()` — 나와 차단 관계인 사용자 id **배열**(2026-08-05, 0032 §7.10). 위와 같은 사실의 집합 형태다. RLS 처럼 **행마다 판정해야 하는 자리**에서는 술어를 쓰면 컬럼 인자 때문에 행별 호출이 되므로 이쪽을 쓰고 `(select app.blocked_ids())` 로 감싼다(§9). **둘은 같은 조건이므로 한쪽만 고치면 안 된다.**
>
> 모두 `STABLE SECURITY DEFINER`, `search_path=''` 로 정의되어 RLS 를 우회해 판별만 수행한다.

---

## 1. 개요

- **테이블 수**(2026-08-04 실측): `public` **36개** (이 중 `spatial_ref_sys` 는 PostGIS 시스템 테이블이므로 실질 애플리케이션 테이블은 **35개**) + `app` 스키마 내부 테이블 **19개**(§3.8)
- **뷰**: 7개 (`public_profiles`, `v_post_feed`, `v_comment_feed`, `v_chat_rooms`, `v_pawing`, `v_pawmate`, `v_facility_review_comment_feed` — §6). PostGIS 가 만드는 `geometry_columns`·`geography_columns` 는 제외
- **RLS 정책** 83개(public 76 + storage 7) · **트리거**(비내부) 77개(public 76 + app 1) · **pg_cron 잡** 10개 · **마이그레이션** 199건
- **ENUM 타입**: 2개 — `public.facility_category`, `app.biz_license_type`(영업 허가 종류: grooming/boarding/sales/production 등, §7.10). 그 외 상태값은 ENUM 대신 `varchar + CHECK` 제약으로 관리한다 — 값 추가에 `alter type` 이 필요 없고, 값을 지우거나 순서를 바꾸는 것도 CHECK 쪽이 쉽다
- **PK 규약**: 대부분 `gen_random_uuid()` 기본값의 UUID. 예외 — `review_category_counts`(복합 PK) · `dong_centroids`·`business_match_rules`(자연키) · `app.client_errors`·`app.business_doc_purge_queue`·`app.funnel_events`(**bigint identity** — 대량 append 로그라 UUID 색인 비용을 피한다) · `app.push_config`·`app.care_config`·`app.business_purge_config`(`id boolean` 싱글턴)
- **커스텀 시퀀스**: `public`·`app` 에는 없다(identity 컬럼이 내부 시퀀스를 쓴다). `auth`·`cron`·`net` 의 것은 플랫폼·확장 소유

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
| 업체 (0025·0028) | business_profiles, business_match_rules |
| 시스템 (PostGIS) | spatial_ref_sys |

> 07-02 이후 `app` 스키마가 3개에서 16개로 늘었다. 대부분 **법정 보존·파기 의무가 붙은
> 기록**(접속 로그·위치 이용 기록·탈퇴자 재가입 확인·업체 서류 파기 큐)과 **관측**
> (클라이언트 오류)이다. 파기 주기는 전부 `app.cleanup_retention()` 한 곳에 모여 있고
> pg_cron `retention-purge` 가 매일 돌린다 — 처리방침 §3 의 이행 지점이다.

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

### public.business_match_rules

업체 매칭 가중치 규칙(0028). 관리자가 조정하는 **설정 테이블**이라 행 수가 적고 자연키(`rule_key`)를 PK 로 쓴다.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| rule_key | varchar | NO | | PK. 규칙 식별자 |
| weight | integer | NO | | 가중치 |
| enabled | boolean | NO | `true` | 끄기만 하고 행은 남긴다(이력 보존) |
| params | jsonb | YES | | 규칙별 파라미터 |
| note | text | YES | | 운영 메모 |
| updated_at | timestamptz | NO | `now()` | |

- **RLS on** — `business_match_rules_admin_select`(SELECT, `app.is_admin()`) 하나뿐. 쓰기는 관리자 RPC(`admin_set_match_rule`) 경유
- ⚠️ `anon` 에 `GRANT ALL` 이 남아 있다(0031 §4 유형 — 2026-06-30 회수 스윕이 **고정 테이블 목록**만 처리해 그 뒤 생성된 테이블이 Supabase 기본 GRANT 를 상속). 지금은 위 정책이 막지만 재발 방지 장치(`ALTER DEFAULT PRIVILEGES`·CI 린트)가 없다

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
| context | varchar | NO | 'personal' | 팔로우한 '얼굴' (personal/business) — 업체 얼굴 팔로우는 목록에서 상호·대표사진으로 표시(개인 닉네임 비노출) |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **PK**: `pawings_pkey` (id)
- **FK**: follower_id → users.id, following_id → users.id
- **UNIQUE**: `pawings_uq` (follower_id, following_id, **context**) — 같은 사용자의 개인/업체 얼굴을 독립적으로 팔로우 가능
- **CHECK**: `pawings_self_chk`: follower_id <> following_id (자기 팔로우 금지)
- **새 글 알림**: `app.dispatch_engagement_notifications()` 의 pawing_new_post 는 글의 `authored_as` 와 같은 `context` 팔로워에게만 발송(업체 소식 → 업체 팔로워)
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
  - `posts_category_check`: category IN ('walk_together','walk_proxy','care','adoption','give_away','free','news') — news(소식)는 업체 전용: BEFORE INSERT 트리거(`app.posts_set_authored_as`)가 업체 모드 글을 news 로 강제, 개인 모드 news 는 예외
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
  - `notifications_notification_type_check`: notification_type IN ('chat_message','post_application','post_comment','pawing_new_post','application_accepted','application_accepted_by_co','review_received','guardian_invite','system_notice','location_expired','chat_read_receipt','unread_sync','security_login','schedule_changed','business_approved','business_rejected','review_comment')
  - `notifications_priority_check`: priority IN ('high','normal','low')
  - `notifications_push_status_check`: push_status IN ('pending','sending','sent','failed','skipped')
  - `notifications_resource_type_check`: resource_type IS NULL OR IN ('post','comment','chat_room','appointment','facility_review')
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
| has_incentive | boolean | NO | false | 업체 혜택(할인·사은품) 받고 작성 — 표시광고법 표시(0028 §6), 카드·상세·share-view 배지 |

- **PK**: `facility_reviews_pkey` (id)
- **FK**: facility_id → facilities.id (**ON DELETE CASCADE**), user_id → users.id (**ON DELETE CASCADE**)
- **UNIQUE**: `facility_reviews_facility_id_user_id_key` (facility_id, user_id)
- **CHECK**:
  - `facility_reviews_rating_check`: 1 ≤ rating ≤ 5
  - `facility_reviews_photos_max`: array_length(photo_paths) ≤ 5
- **인덱스**: `facility_reviews_facility_idx` (facility_id, created_at DESC)

### public.facility_review_comments

시설 후기 댓글 (소프트 삭제, 업체 모드 작성 시 상호 노출 — 게시글 comments 문법 미러링).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| review_id | uuid | NO | | 후기 FK (**ON DELETE CASCADE**) |
| user_id | uuid | NO | | 작성자 FK (**ON DELETE CASCADE**) |
| content | text | NO | | 내용 (trim 1~1000자, `frc_content_len`) |
| authored_as | varchar | NO | 'personal' | 작성 시점 계정 모드 스냅샷 (personal/business) |
| is_deleted | boolean | NO | false | 소프트 삭제 |
| deleted_at | timestamptz | YES | | 삭제 시각 (`trg_frc_soft_delete_ts` 스탬프) |
| created_at | timestamptz | NO | now() | 생성 시각 |

- **RLS**: SELECT(미삭제 또는 admin) / INSERT(본인) / UPDATE(본인 또는 admin). anon 은 SELECT 만.
- **트리거**: `trg_frc_authored_as`(BEFORE INSERT, `app.comments_set_authored_as` 재사용), `trg_frc_soft_delete_ts`(BEFORE UPDATE), `trg_notify_review_comment`(AFTER INSERT — 후기 작성자에게 `review_comment` 알림, 본인 제외).
- **조회**: `v_facility_review_comment_feed` 뷰(업체 모드 댓글은 상호로 표시, 미삭제만). anon/authenticated SELECT.
- **푸시**: `_push_pref_allows` 에서 `review_comment` 는 post_comment(댓글) 토글을 따른다.

### public.facility_cache

외부 지도 API 장소 검색 결과 캐시 (TTL: expires_at). FK 없음. 지도 연동은 **네이버지도 API로 통일** — NCP Maps 지오코딩 + 네이버 지역검색(supabase-api.md `search-petcafe` 참조). `kakao_*` 컬럼명/기본값은 초기 설계의 레거시 명칭.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| kakao_place_id | varchar | NO | | 외부 장소 ID (네이버 place id — 컬럼명은 레거시) |
| source_provider | varchar | NO | 'kakao' | 제공자 — 현재 `'naver'`로 통일 (기본값 'kakao'는 레거시) |
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
  - `photo_verifications_purpose_check`: purpose IN ('reference','post','pet_identity') — 'pet_identity'는 20260713112529에서 추가(varchar(20) 확장은 20260713112812)
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

인증 인프라·운영 전용 내부 테이블 19개. 클라이언트(PostgREST)에 노출되지 않으며(`app` 스키마는 API 스키마가 아님), SECURITY DEFINER 함수와 Edge Function(service_role)만 접근한다. RLS 없이 스키마 격리로 보호.

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

### app.business_licenses

업종별 등록·허가 증빙 (0028 §1) — approved 행 존재 = 해당 업종 모듈 ON(`app.has_license`).
0025 `business_profiles`(사업자 단위 인증) 아래의 업종 단위 층. 자동승인 없음(관리자 수동 검토).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| user_id | uuid | NO | | → users(id) CASCADE |
| license_type | app.biz_license_type | NO | | grooming(미용)·boarding(위탁관리)·sales(판매)·production(생산)·exhibition(전시)·transport(운송) |
| license_no | varchar(40) | NO | | 지자체 등록·허가번호(형식 자유) |
| document_path | text | NO | | 등록·허가증 사본 — `business-docs` 비공개 버킷, `uid/` 프리픽스 강제 |
| status | varchar(12) | NO | 'pending' | pending/approved/rejected — CHECK |
| reject_reason | text | YES | | 반려 사유 |
| reviewed_by / reviewed_at | | YES | | 심사자·시각 |
| created_at / updated_at | timestamptz | NO | now() | `trg_business_licenses_updated` |

- **UNIQUE**: (user_id, license_type) — 계정당 업종별 1행(재신청은 갱신).
- 반려 서류는 6개월 후 파기 큐(`business_doc_purge_queue`, 재신청 시 회수), 교체 서류는 1개월.
- 게이트: `app.has_license(p_type)` [SD] — 도구 RPC 첫 줄에서 호출(클라이언트 직접 호출 경로 없음).
- RPC: `apply_business_license(p_type, p_license_no, p_document_path)` (업체 인증 **pending 부터** 신청 가능 — 등록 폼 동시 제출 지원, 본인 폴더 경로만), `my_business_licenses()`, `admin_list_business_licenses(p_status='pending', ...)` [admin], `admin_review_business_license(p_license, p_status, p_reason?)` [admin — 반려 사유 필수, **승인은 업체 인증 approved 선행 필수(business_not_approved)**, business_approved/rejected 알림 재사용, admin_logs 기록].

### app.share_links

설치 전 가치 전달용 공유 링크 (0028 §3, `share-view` Edge Function 이 서빙).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| token | varchar(32) | NO | | PK. 16바이트 랜덤 hex(서버 생성, 추측 불가) |
| kind | varchar(20) | NO | | `facility_preview`(매장 QR 미리보기) \| `care_report`(P1 예정) — CHECK |
| ref_id | uuid | NO | | kind 별 대상(시설 id, 리포트 id …) |
| created_by | uuid | NO | | 발급자 → users(id) CASCADE |
| expires_at | timestamptz | NO | | 만료 — facility_preview 기본 365일 |
| view_count | integer | NO | `0` | 열람 수(share_view_load 가 원자 증가) |
| revoked_at | timestamptz | YES | | 회수 시각(admin_revoke_share_link) |
| created_at | timestamptz | NO | `now()` | |

- 인덱스: `share_links_ref_idx` (kind, ref_id) — 대상→링크 역조회.
- 접근: 클라이언트 롤 접근 없음(app 스키마). Edge Function 도 service_role 전용 public RPC(`share_view_load`/`share_view_click`)를 경유.

### app.funnel_events

오프라인 제휴 파일럿 퍼널 계측 (0028 §7). 원시 이벤트 보존 1년(경과분 배치 삭제 예정).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | bigint | NO | identity | PK |
| event | varchar(30) | NO | | `share_view` \| `store_click` \| `signup` \| `claim` … |
| token | varchar(32) | YES | | share_links 귀속(있으면) — 매장·도구별 전환 집계 축 |
| user_id | uuid | YES | | 가입 이후 이벤트만 |
| props | jsonb | NO | `'{}'` | 이벤트 부가 정보 |
| created_at | timestamptz | NO | `now()` | |

- 인덱스: `funnel_events_token_idx` (token, event).

### app.care_config

케어 리포트 전화번호 HMAC 키 싱글턴 (0028 §4.2). RLS 정책 없음 = definer 전용.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | boolean | NO | `true` | PK + CHECK — 싱글턴 |
| hmac_key | text | NO | `gen_random_bytes(32)` hex | 수신자 번호 키드 해시용(무염 해시는 번호 전수대입에 취약) |
| key_version | smallint | NO | `1` | 키 유출 시 무마이그레이션 로테이션용 선점(평시 단일 키) |

### app.care_reports

업체→보호자 케어 리포트 (0028 §4 — P1 미용 전후 사진, P2 알림장 공용 원형).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| business_id | uuid | NO | | 발행 업체 → users(id) CASCADE |
| kind | varchar(12) | NO | | `grooming`(v1) \| `boarding`(P2) — CHECK |
| pet_label | varchar(50) | NO | | 업체가 입력한 아이 이름(미가입 보호자 전제) |
| photos | jsonb | NO | `'[]'` | 사진 URL 배열(1~4장, 미용은 전/후 2장 기본) |
| body | jsonb | NO | `'{}'` | kind 별 확장(boarding 식사·배변 등, P2) |
| note | text | YES | | 한 줄 메모 |
| recipient_phone_hmac | bytea | YES | | 수신자 번호 키드 해시 — **선택 입력**, claim 성사 시 즉시 null 파기, 미연결분은 링크 만료 후 크론 파기 |
| recipient_key_version | smallint | NO | `1` | 해시 시점 키 버전 |
| claimed_by / claimed_at | | YES | | 연결 보호자·시각(첫 claim 후 잠금) |
| created_at | timestamptz | NO | now() | |

- 인덱스: business(발행 목록)·phone(미연결 부분)·claimed(받은 목록).
### app.care_threads

위탁 알림장 스레드 (0028 §4.4) — 반려동물×업체 **상시 1개**, '위탁 건' 엔티티 없음.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | gen_random_uuid() | PK |
| business_id | uuid | NO | | 업체 → users(id) CASCADE |
| pet_label | varchar(50) | NO | | 아이 이름(유니크 아님 — 동명 두 아이 실존, 스레드 선택은 업체 UI) |
| recipient_phone_hmac / recipient_key_version | | YES | | 스레드 단위 수신자(선택). claim 성사 시 파기, 미연결분은 마지막 발행 30일 후 크론 파기 |
| claimed_by / claimed_at | | YES | | 연결 보호자 — 연결되면 이후 발행이 즉시 보이고 도착 알림 발송 |
| last_report_at | timestamptz | YES | | 발행 시 갱신 — **보관은 파생값**(`boarding_archive_days`, care_config 기본 7) |

- RPC: `create_care_thread(p_pet_label, p_recipient_phone?)` [SD, `has_license('boarding')`], `create_boarding_report(p_thread, p_photos?, p_body?, p_note?)` [SD — 빈 발행 거부, 단건 공유 링크(care_report 30일)+funnel, 연결 보호자 알림], `my_care_threads()` (archived 파생·최근 사진), `care_thread_reports(p_thread, ...)` (업체 소유 또는 연결 보호자만).
- `claim_care_reports()` 는 단건 리포트에 더해 **스레드 단위 자동 연결**(기존 기록 포함) 수행.
- `my_received_care_reports()` 반환에 `body`·`thread_id` 추가(반환형 변경 재생성).

- RPC: `create_care_report(p_pet_label, p_photos, p_note?, p_recipient_phone?)` [SD, `has_license('grooming')` 게이트] — share_links(kind `care_report`, 30일) 토큰 생성 + funnel `report_issued`. `my_care_reports()`(발행 목록, 수령자 닉네임 표시), `claim_care_reports()`(인증 번호 HMAC 대조 자동 연결 — 가입/앱 시작 시 호출, 알림 `system_notice` + funnel `claim`, hmac 파기), `my_received_care_reports()`(보호자 받은 목록).

### app.auth_logs

로그인 **성공** 접속 기록. 통신비밀보호법상 접속기록 보존(3개월) 대상이며 처리방침 §3 에 등재돼 있다. 실패한 로그인은 남기지 않는다 — 0031 §2.1 이 지적한 "성공했을 때만 흔적이 남는다" 가 여기서 온다.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | `gen_random_uuid()` | PK |
| user_id | uuid | NO | | FK → public.users.id |
| ip_hash | text | YES | | **SHA-256 해시**. 평문 IP 는 저장하지 않는다(처리방침 §1-1 과 일치) |
| created_at | timestamptz | NO | `now()` | |

- **인덱스**: `idx_auth_logs_created`(created_at)
- **RLS on, 정책 없음** — service_role 전용(의도적)
- 3개월 경과분은 `app.cleanup_retention()` 이 파기(pg_cron `retention-purge`)

### app.location_usage_logs

**위치정보 이용·제공사실 확인자료**(위치정보법 제16조 제2항). 6개월 보존 후 파기 — 법정 의무라 파기 누락이 곧 위반이다.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | `gen_random_uuid()` | PK |
| user_id | uuid | NO | | FK → public.users.id |
| purpose | text | NO | | 이용 목적 |
| provided_to | text | YES | | 제3자 제공 시 대상(현재 제공 없음 — 위치기반 약관 제9조) |
| used_at | timestamptz | NO | `now()` | |

- **인덱스**: `idx_location_usage_logs_used`(used_at), `idx_location_usage_logs_user`(user_id, used_at DESC)
- **RLS on, 정책 없음** — service_role 전용
- 6개월 경과분 파기 + 탈퇴 시 즉시 삭제(`20260712041855`)

### app.withdrawn_users

탈퇴 회원 **재가입 확인 정보**(아이디·전화번호, 30일). 부정 재가입 방지 목적이며 처리방침 §3 에 등재돼 있다. 본체 `users` 행은 `withdraw_account` 가 익명화하므로, 재가입 판정에 필요한 최소 정보만 여기 따로 둔다.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| user_id | uuid | NO | | PK |
| username | text | YES | | |
| phone | text | YES | | |
| withdrawn_at | timestamptz | NO | `now()` | |

- **RLS on, 정책 없음** — service_role 전용
- 30일 경과분은 pg_cron `withdrawn-users-purge` 가 삭제

### app.client_errors

클라이언트 오류 리포팅(**`reported` 등급만** — 0011 ADR). 30일 보존 후 파기하며 처리방침 §1-1·§3 에 등재돼 있다(2026-08-04 개정, 0032 §5.2).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | bigint | NO | identity | PK |
| user_id | uuid | YES | | 로그인 중이면 기록. 비로그인 오류도 받는다 |
| where_key | varchar | NO | | 발생 위치 태그(예: `session.refresh.rejected`) |
| message | varchar | NO | | 오류 메시지 |
| stack | text | YES | | 스택 트레이스 |
| platform | varchar | YES | | ios / android / web |
| app_release | varchar | YES | | `Env.appRelease` — 배포별 급증 판정용 |
| extra | jsonb | YES | | 호출부가 붙인 진단 컨텍스트 |
| created_at | timestamptz | NO | `now()` | |

- **인덱스**: `client_errors_recent_idx`(created_at DESC), `client_errors_where_idx`(where_key, created_at DESC)
- **접속 IP 는 저장하지 않는다.** `record_client_error` 가 `cf-connecting-ip` 를 읽지만 md5 해시를 **레이트리밋 버킷 키로만** 쓰고 테이블에는 남기지 않는다
- 쓰기는 `public.record_client_error`(SD) 경유 — 개별 30/분 + 익명 전역 300/분
- ⚠️ 모으기만 하고 **알려 주는 장치가 없다**(0031 §6.1) — 임계 알람 미구현

### app.vaccination_events

분양 스타터 접종 리마인더(0028 §5). 일정 콘텐츠는 앱이 갖고, 서버는 저장·알림만 한다.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | uuid | NO | `gen_random_uuid()` | PK |
| pet_id | uuid | NO | | FK → public.pets.id |
| label | varchar | NO | | 접종 항목명 |
| due_date | date | NO | | 예정일 |
| done_at | timestamptz | YES | | 완료 표시 |
| notified_at | timestamptz | YES | | 리마인더 발송 잠금 — 중복 알림 방지 |
| created_by | uuid | NO | | FK → public.users.id |
| created_at | timestamptz | NO | `now()` | |

- **인덱스**: `vaccination_events_pet_idx`(pet_id, due_date), `vaccination_events_due_idx`(due_date) **부분**(`done_at is null and notified_at is null`)
- **이 테이블만 RLS off** — 접근이 전부 SD RPC 경유라 정책을 두지 않았다
- pg_cron `vaccine-reminder-sweep`(매일 00:00 UTC)가 D-1 이내 미완료분을 보호자에게 1회 알림
- ⚠️ 날짜 판정은 **KST 기준**(`now() at time zone 'Asia/Seoul'`). 테스트가 `current_date`(UTC)로 준비해 **매일 아침 9시간만 실패**하던 사고가 있었다(0032 §6.6)

### app.business_doc_purge_queue

업체 증빙 서류(Storage 객체) **파기 대기열**. 0025 §3.3·§8 의 파기 의무 이행 지점.

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | bigint | NO | identity | PK |
| path | text | NO | | Storage 객체 경로 |
| reason | text | NO | | 큐 사유(반려·탈퇴·서류 교체 등) |
| purge_after | timestamptz | NO | | 이 시각 이후 파기 |
| purged_at | timestamptz | YES | | 완료 표시. NULL 이면 미처리 |
| created_at | timestamptz | NO | `now()` | |

- **RLS on, 정책 없음** — service_role 전용
- pg_cron `business-docs-purge` 가 `purge-business-docs` Edge Function 을 호출해 실제 삭제
- ⚠️ storage remove 실패 행은 큐에 남아 **조용히 무한 재시도**한다. 자기 치유되지 않는 실패(경로 부재·권한 변경)면 파기 의무가 무기한 미이행인데 관측 수단이 없다(0032 §9.2)

### app.business_purge_config

위 배치가 부를 Edge Function 주소와 공유 시크릿. `id boolean` 싱글턴(행 1개 강제).

| 컬럼 | 타입 | Null | 기본값 | 설명 |
|---|---|---|---|---|
| id | boolean | NO | `true` | PK — 싱글턴 강제 |
| function_url | text | NO | | `purge-business-docs` 엔드포인트 |
| trigger_secret | text | NO | `encode(gen_random_bytes(24),'hex')` | `x-purge-secret` 헤더로 전달 |

- **RLS on, 정책 없음** — service_role 전용. 시크릿을 담으므로 노출 경로가 없어야 한다

### app.ops_alarm_config

운영 알람 임계값. `id boolean` 싱글턴. **임계값을 코드가 아니라 DB 에 두는 이유**: 출시 직후 트래픽을 모르는 상태에서 고른 숫자라 반드시 조정하게 되는데, 그때마다 마이그레이션을 치고 싶지 않다.

| 컬럼 | 기본값 | 뜻 |
|---|---|---|
| enabled | true | 전체 스위치 |
| window_minutes | 15 | 관측 창 |
| cooldown_minutes | 60 | 같은 알람 재발사 억제 |
| client_error_per_key | 20 | 한 지점(`where_key`)에서 창 내 이 건수면 발사 |
| client_error_total | 100 | 지점 무관 총량 |
| rate_limit_trips | 100 | 한 계열의 창 내 차단 횟수 |
| push_failed | 20 | 창 내 푸시 실패 건수 |
| cron_failed | 1 | 창 내 크론 실패 건수 |
| purge_overdue_hours | 24 | 이 시간 넘게 안 지워진 증빙이 **1건이라도** 있으면 발사 |

> ⚠️ **이 INSERT 는 데이터라 `pg_dump --schema-only` 에 안 담긴다.** 스냅샷으로 세운
> DB(CI·재해복구)에서는 이 테이블이 비어 있다. 그래서 `app.ops_alarm_sweep()` 은 행이
> 없으면 **조용히 꺼지는 대신 기본값 행을 다시 넣고 진행한다** — 알람이 죽은 걸 알람이
> 알려 줄 수는 없기 때문이다.

### app.ops_alarms

발사된 알람 이력. `bigint identity` PK.

| 컬럼 | 뜻 |
|---|---|
| alarm_key | 쿨다운 단위(`client_error:<지점>`, `ratelimit:<계열>`, `push_failed`, `cron_failed`, `purge_overdue`) |
| title / body | 알림에 그대로 나가는 문구 |
| detail | jsonb — 건수·창 길이 등 근거 |
| fired_at | 발사 시각 |

- 이력을 따로 남기는 이유: 알람은 푸시로 나가는데 **푸시 파이프라인이 죽으면 그 알람도 못 온다.** 이력·앱 내 알림·푸시 세 군데에 남겨 한 경로가 죽어도 되짚을 수 있게 한다. 조회는 `admin_ops_alarms`(§7.9).
- 보존 30일(`retention-purge`). `client_errors` 와 같은 기간으로 맞췄다 — 같이 보게 되는 자료라 기간이 다르면 "왜 이때는 알람이 없지" 가 보존 차이인지 실제인지 구분이 안 된다.

### app.rate_limit_trips

레이트리밋이 **실제로 막은** 횟수. PK `(family, minute)`.

- `family` = 버킷 키의 첫 토큰(`login:ip:1.2.3.4` → `login`). 개별 식별자(uid·전화·IP)는 **일부러 버린다** — 알람은 "어느 계열이 얼마나 막혔나" 를 답하면 되고, 누가 막혔는지까지 남기면 보관할 이유 없는 개인정보가 된다.
- 분 단위로 접는다. 공격 중 발동은 초당 수백 건이 될 수 있어 발동마다 한 행이면 관측하려다 테이블을 채운다.
- 기록은 `public.rate_limit_hit` 이 **초과했을 때만** 한다. 그 INSERT 는 예외를 삼킨다 — 관측이 제한기를 죽이면 안 된다.
- 종전에는 발동이 **아무 흔적도 남기지 않았다**(카운트만 세고 버렸다). 0032 §9.3 의 항목.

### pg_cron 스케줄 잡

| 잡 이름 | 스케줄 | 동작 |
|---|---|---|
| `auth-cleanup` | `17 * * * *` (매시 17분) | `app.cleanup_auth()` — 만료/오래 회수된 refresh_tokens + 만료 rate_limits 삭제 |
| `push-sweep` | `* * * * *` (매분) | `push_status='pending'` 알림이 존재할 때만 `app.push_config`의 URL 로 `net.http_post` — 재시도/누락 보완 스윕 (§8 트리거의 즉시 발사와 이중화) |
| `withdrawn-users-purge` | `43 3 * * *` (매일 03:43) | `delete from app.withdrawn_users where withdrawn_at < now() - interval '30 days'` — 탈퇴자 격리 30일 후 삭제 |
| `funnel-events-retention` | `53 3 * * *` (매일 03:53) | `delete from app.funnel_events where created_at < now() - interval '1 year'` — 퍼널 원시 이벤트 보존 1년 (0028 §7) |
| `care-report-hmac-purge` | `58 3 * * *` (매일 03:58) | 링크 만료(30일) 지난 미연결 케어 리포트 + 마지막 발행 30일 지난 미연결 스레드의 `recipient_phone_hmac` 파기 (0028 §4.2) |
| `engagement-sweep` | `* * * * *` (매분) | `app.dispatch_engagement_notifications()` — 팔로우 새 글 등 참여 알림 배치 |
| `vaccine-reminder-sweep` | `0 0 * * *` (매일 00:00) | KST 기준 오늘·내일 예정 접종에 `vaccine_reminder` 알림(발송분은 `notified_at` 으로 1회 보장) |
| `business-docs-purge` | `13 4 * * *` (매일 04:13) | `app.business_purge_config` 의 URL 로 `net.http_post` — `purge-business-docs` 기동(증빙 파기) |
| `ops-alarm-sweep` | `*/5 * * * *` (5분마다) | `app.ops_alarm_sweep()` — 오류 급증·레이트리밋 다발·푸시 실패·크론 실패·파기 적체를 보고 관리자에게 알린다. 창(15분)보다 짧아야 급증이 창 밖으로 빠져나가기 전에 잡힌다 |
| `retention-purge` | `23 3 * * *` (매일 03:23) | `app.cleanup_retention()` — 전화 인증코드 1일 / 위치 인증 이력·사진 인증 로그 6개월 / **삭제·탈퇴자 게시글 실좌표 스크럽** / **post_views(ip_hash)·app.auth_logs(접속 로그) 3개월** 파기 / **소프트 삭제된 채팅 메시지 30일 유예 후 하드 삭제**(신고 대응 기간 확보 후 파기). photo_verifications 는 pets·posts FK 참조 때문에 미참조 행만 삭제·참조 행은 촬영 좌표(shot_*)만 스크럽 (→ §13 `20260711130000`·`20260711140000`) |

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
SELECT pr.id AS user_id,
       (CASE WHEN p.context='business' THEN coalesce(pr.business_name,'업체')
             ELSE pr.nickname END)::varchar(50) AS nickname,
       pr.user_type, p.created_at,
       (CASE WHEN p.context='business' THEN pr.business_photo_url
             ELSE pr.profile_image_url END) AS profile_image_url,
       (p.context='business') AS is_business,
       (CASE WHEN p.context='business' THEN pr.business_name END) AS business_name
  FROM pawings p
  JOIN public_profiles pr ON pr.id = p.following_id
 WHERE p.follower_id = app.uid();
```

- **무엇을 반환**: 내가(=`app.uid()`) 팔로우(포잉)한 사용자들의 프로필 요약 + 팔로우 시각.
- **업체 얼굴 팔로우**(`pawings.context='business'`)는 상호·대표사진으로 표시하고 개인 닉네임·사진은 싣지 않는다(업체↔개인 연결 비노출, 0025).
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

### 6.7. `v_facility_review_comment_feed` — 시설 후기 댓글 피드

시설 후기의 댓글 목록. 작성자 표시를 뷰가 담당한다 — 업체 모드 댓글은 **상호**로,
개인은 닉네임으로. 간이 회원(`status='lite'`)이 쓴 후기의 작성자는 `app.mask_phone`
으로 일부만 가려 보여 준다.

- `security_invoker`, anon/authenticated SELECT
- 차단 필터 포함(`app.is_blocked_pair`) — 뷰 3종과 같은 축
- 앱: `FacilityReviewRepository.fetchComments`

> ⚠️ 이 뷰를 포함해 피드 뷰들은 수정 시 **본문을 통째로 다시 붙여넣는** 방식으로
> 관리돼 왔다(`v_post_feed` 8회·`v_chat_rooms` 10회 재정의). 차단 필터는 가장 마지막
> 정의에만 있으므로, 다음 수정이 이전 본문을 복사하면 조용히 사라진다.
> `replay_check` 는 스냅샷↔리플레이 *일치*만 보므로(양쪽 다 빠지면 통과) 이 회귀를
> 잡지 못한다 — pgTAP 커버리지도 0이다(0031 §7 후속 항목).

---

## 7. 데이터베이스 함수(RPC)

public 스키마에 **109개**의 함수가 있다(PostGIS 확장 함수 제외, 이벤트 트리거 함수 `rls_auto_enable` 포함) — 클라이언트 호출 가능 80개 + service_role 전용 29개. 2026-08-04 실측.
거의 전부 `SECURITY DEFINER` + `SET search_path` 고정. 실행 권한(EXECUTE) 관점에서 두 부류로 나뉜다 — §10 참조:

- **클라이언트 호출 가능(anon/authenticated EXECUTE)**: 일반 RPC.
- **service_role 전용**: 인증/토큰/검증 기록/푸시 파이프라인 등 서버(Edge Function·백엔드)만 호출.

아래는 도메인별 전체 목록이다. (표기: `[SD]` = SECURITY DEFINER, `[svc]` = service_role 전용)

### 7.1. 인증·계정 (Auth)

> **비밀번호 해싱 (20260710~)**: bcrypt(pgcrypto) → **argon2id** 로 전환. 해싱·검증은 엣지펑션
> (`_shared/passwords.ts`, hash-wasm, m=19MiB/t=2/p=1)에서 수행하고 DB 는 해시 문자열만 다룬다 —
> 평문 비밀번호가 SQL 계층에 도달하지 않는다. 기존 `$2a$…`(bcrypt) 해시는 접두사 분기로 계속
> 검증되며, 로그인 성공 시 `update_password_hash`(CAS)로 argon2id 재해싱(점진 전환, 세션 유지).

#### `signup_user(p_username, p_password_hash, p_nickname, p_user_type, p_phone, p_marketing=false) → uuid` [SD][svc]
회원가입(해시는 signup 엣지가 argon2id 로 생성해 전달). 로직:
1. `phone_verifications` 에 해당 전화의 `purpose='signup'`, `is_used=true`, 30분 이내 레코드가 없으면 `phone_not_verified`(P0001) 예외.
2. username/nickname(소문자 비교)/phone 중복이면 각각 `username_taken`/`nickname_taken`/`phone_taken`(P0001).
3. `users` INSERT(`phone_verified=true`, `terms_agreed_at=now()`, 마케팅 동의 기록), 새 id 반환.
- 부수효과: `trg_users_after_insert` 트리거가 알림 설정 기본행·고객센터 채팅방·대기 중 보호자 초대 연결을 자동 생성(§8 참조).

#### `get_login_user(p_username) → TABLE(id, username, nickname, user_type, password_hash)` [SD][svc]
- username(대소문자 무시) + `status='active'` 행을 해시 포함 반환(0 또는 1행). **비번 검증은 login 엣지**가
  수행(argon2id/bcrypt 겸용 + 계정 미존재 시 더미 해싱으로 타이밍 열거 방지) 후 JWT 발급.

#### `update_password_hash(p_user, p_old_hash, p_new_hash) → boolean` [SD][svc]
- 점진 재해싱용 CAS 갱신: `password_hash = p_old_hash` 일 때만 교체(동시 비번변경 레이스 방지). 세션 무효화 없음.

#### `get_password_hash(p_user) → text` [SD][svc]
- active 사용자의 현재 해시 반환 — change-password 엣지의 현재 비번 검증용.

#### `check_username_available(p_username) → boolean` [SD]
- `lower(username)` 중복이 없으면 true. 가입 폼의 아이디 중복확인용. anon 호출 가능.

#### `check_nickname_available(p_nickname) → boolean` [SD]
- `lower(trim(p_nickname))` 중복이 없으면 true(호출자 본인 행은 제외 — 안 바꾸고 저장해도 통과).
- 내정보 수정 폼의 실시간 선체크용 — 최종 판정은 `users_lower_nickname_uq` 가 한다(경합 시 23505).
- authenticated 만 호출 가능(가입 시점 중복은 signup 엣지가 `nickname_taken` 으로 처리).

#### `reset_password_user(p_phone, p_new_password) → uuid` [SD][svc]
비밀번호 재설정(새 비번 규칙 검사·argon2id 해싱은 reset-password 엣지에서):
1. `phone_verifications` 에 `purpose='password_reset'`, `is_used=true`, 30분 이내 기록 필요 — 없으면 `phone_not_verified`(P0001).
2. 전화번호로 사용자 조회, 없으면 `user_not_found`(P0001).
3. 해시 갱신 + `token_version+1`(모든 액세스토큰 무효화) + 미회수 refresh token 전부 revoke. 사용자 id 반환.
- 시그니처: `reset_password_user(p_phone, p_new_hash)`.

#### `change_password_and_rotate(p_user, p_current_hash, p_new_hash, p_tv, p_new_token_hash, p_user_agent?) → integer` [SD][svc]
- 세션 검증(active + `token_version = p_tv`, 불일치 시 `not_authenticated` 42501) 후 해시 CAS 갱신
  (`password_hash = p_current_hash` 일 때만 — 0행이면 `invalid_current` P0001 로 전체 롤백),
  `token_version+1`, 기존 refresh token 전부 revoke, **새 refresh token(해시) 즉시 발급**(30일/절대 90일).
  새 token_version 반환. "비번 변경해도 현재 기기 세션은 유지" 흐름.
  현재 비번 검증(및 6자 미만 `weak_password`)은 change-password 엣지가 수행.
- 드롭됨(평문 경로 제거): `login_user`, `change_password`, `change_password_svc`, `app._set_password`.

#### `bump_token_version(p_user) → integer` [SD][svc]
- `token_version+1` 후 반환. 전체 강제 로그아웃 스위치.

#### `session_alive() → boolean` (SECURITY INVOKER)
- `app.uid() is not null`. 클라이언트가 토큰 유효성(만료/버전 불일치/정지)을 가볍게 확인하는 핑.

#### `withdraw_account() → void` [SD]
- 탈퇴. 행을 지우지 않고 **익명화**한다 — `username='del_<10자>'`, 닉네임 `탈퇴회원<10자>`, 비밀번호 `'!'`(검증 불가 sentinel), 전화·주소·좌표·프로필 이미지 전부 NULL, `status='deleted'`, `token_version+1`(전 세션 즉시 무효). 지우기 전에 `app.withdrawn_users` 에 (user_id, username, phone) 을 남겨 **재가입 쿨다운**에 쓰고, 그 보관분은 30일 뒤 `withdrawn-users-purge` 크론이 지운다.
- 행을 남기는 이유: 게시글·댓글·후기의 FK 와 대화 상대 표시가 깨지지 않게 하기 위함. 남는 건 식별 불가능한 껍데기다.

#### `switch_account_mode(p_mode) → text` [SD]
- `personal`/`business` 만 허용. business 로 가려면 **승인된** `business_profiles` 가 있어야 한다(`business_not_approved`). `users.active_mode` 를 바꾼다 — 이후 작성물의 `authored_as` 스탬프와 각종 `assert_*_actor()` 게이트가 이 값을 본다.

#### `block_user(p_blocked, p_reason?) → void` [SD]
- 차단. `user_blocks` upsert + 신고 접수에 더해 **관계 자체를 끊는다**(2026-08-04 확장, 0032 §2): 팔로우 양방향 삭제, 그리고 공유 채팅방의 `last_read_message_id` 를 방 끝으로 밀어 안읽음 카운트를 정리한다.
- 팔로우를 지우는 이유: 남겨 두면 크론이 그 사람에게 `pawing_new_post` 를 계속 보내고(알림 필터가 막긴 하지만), 차단 해제 시 예전 팔로우가 되살아난다. 안읽음을 미는 이유: `v_chat_rooms` 가 차단 상대 방을 목록에서 빼므로 **열어서 읽을 방법이 없어져** 배지가 영구히 남는다.
- 자기 차단(`cannot_block_self`)·없는 사용자(`user_not_found`)는 P0001.

#### `reconcile_my_unread_counts() → void` [SD]
- 본인 `unread_chat_count`·`unread_notification_count` 를 원본에서 재계산(`app.reconcile_unread_counts`). 알림 하드 삭제(회수 트리거)·차단 등으로 캐시가 어긋날 수 있어 **로그인 시 안전망**으로 호출한다.

#### `public_user_pets(p_user) → TABLE` / `pet_guardians_of(p_pet) → TABLE` [SD]
- 프로필 화면용 공개 조회. 전자는 그 사용자가 보호 중인 펫 목록(삭제 펫 제외, owner 우선 정렬, 보호자 수 포함), 후자는 그 펫의 보호자 목록(탈퇴·비활성 사용자 제외, owner 우선). 둘 다 SECURITY DEFINER 라 RLS 를 우회하지만 **공개해도 되는 컬럼만** 고른다.

#### `record_auth_log(p_user, p_ip_hash) → void` [SD][svc]
- 로그인 성공 기록을 `app.auth_logs` 에 남긴다. IP 는 원본이 아니라 해시(빈 문자열은 NULL).

#### `signup_lite_user(p_phone, p_privacy_consent) → uuid` [SD][svc]
- 간이 후기 계정 생성/조회 — `signup-lite` Edge Function 전용. **같은 번호는 항상 같은 계정**을 돌려준다.
- 동의(`privacy_consent_required`)와 **`purpose='review'` 전화 인증 30분 이내**(`phone_not_verified`)를 요구한다. purpose 를 `signup` 과 분리한 이유: `send-phone-code` 가 signup 목적은 이미 가입된 번호를 거부하는데, 간이 후기는 정식 회원도 쓸 수 있어야 한다.
- 정지·탈퇴 계정은 이 경로로 되살릴 수 없다(`account_unavailable`). username/nickname 은 자동 생성값이고 표시는 `app.mask_phone` 이 담당한다.

### 7.2. Refresh Token 회전 (모두 [SD][svc] — 서버만 호출)

`app.refresh_tokens` 테이블(token_hash, family_id, expires_at 30일, absolute_expires_at 90일, revoked_at, replaced_by)을 다룬다.

#### `rt_issue(p_user, p_token_hash, p_user_agent?) → integer`
- 새 refresh token 해시를 새 family 로 INSERT, 사용자의 token_version 반환.

#### `login_issue_refresh(p_user, p_token_hash, p_user_agent?) → integer`
- `rt_issue` 와 동일하되, **이미 살아있는 다른 refresh token 이 있으면** `security_login` 시스템 알림("새 기기에서 로그인되었어요")을 생성. token_version 반환.

#### `rt_rotate(p_old_hash, p_new_hash, p_user_agent?, p_grace_seconds=30) → TABLE(result, user_id, token_version)`
Refresh token 회전(재사용 감지 + 유실 복구 포함). 반환 `result` 값:
1. 해시 미존재 → `'invalid'`.
2. 사용자 비활성 → family 전체 revoke 후 `'inactive'`.
3. 만료(절대/일반) → `'expired'`.
4. 미회수 토큰이면 원자적으로 revoke 후 같은 family 로 새 토큰 발급, `replaced_by` 연결 → `'rotated'` + token_version.
5. revoked 인데 `replaced_by` 가 **없으면**(로그아웃/패밀리 회수로 죽은 토큰) grace 없이 → `'reuse_revoked'` (로그아웃 직후 재사용으로 세션 부활 방지).
6. 회전으로 revoke 된 토큰의 `p_grace_seconds`(기본 30초) 이내 재시도 → `'grace'` 로 새 토큰 발급 (동시 요청 경합 허용).
7. grace 초과라도 **후속 토큰(replaced_by)이 한 번도 회전되지 않았다면** 회전 응답 유실 재시도로 판정 — 미사용 후속을 revoke 하고 새 토큰 재발급 → `'recovered'` (세션 소실 버그 수정, 패밀리당 5회/일 `rate_limit_hit('rtrec:…')` 제한으로 핑퐁 악용 차단).
8. 후속이 이미 사용됐거나 복구 한도 초과 → **토큰 탈취 의심**으로 family 전체 revoke → `'reuse_revoked'`.

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

#### `update_my_post(p_post, p_title, p_content, p_scheduled_at, p_image_*, p_edit_image, ...) → void` [SD]
- 본인 글만(`not_owner`), 제목·내용 필수. **그 글에 `completed` 약속이 하나라도 있으면 수정이 잠긴다**(`appointment_completed`) — 거래가 끝난 뒤 내용이 바뀌면 후기·신고의 근거가 사라지기 때문. `edited_at` 스탬프.

#### `post_edit_locked(p_post) → boolean` [SD]
- 위 잠금 여부를 UI 가 미리 묻는 용도. 저장 버튼을 눌러야 알 수 있으면 사용자가 헛수고를 한다.

#### `create_post_share_link(p_post) → TABLE(token, expires_at)` [SD]
- visible 글에 대해 30일짜리 공유 토큰 발급. **유효한 기존 링크가 있으면 재사용**(재호출로 이미 퍼진 링크가 죽지 않게). 발급 시 `app.funnel_events` 에 `post_share` 기록.

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

#### `add_facility_review(p_facility, p_rating, p_body, p_paths?, p_urls?, p_has_incentive=false) → uuid` [SD]
- 로그인 필수, 평점 1~5 검증, 자기 업체(형제 시설 포함) 후기는 `own_facility` 거부. `p_has_incentive` 는 대가성 표시(0028 §6) — default 라 구버전 앱(5인자 호출)도 동작. 트리거가 시설 평균평점/리뷰수 재계산.

#### `delete_facility_review(p_facility) → void` [SD]
- 내 리뷰를 `visibility_status='deleted_by_user'` 로 soft delete.

#### `facility_reviews_of(p_facility, p_limit=20, p_offset=0) → TABLE(..., is_mine, visit_no, has_incentive)` [SD]
- visible 리뷰를 최신순 페이지네이션(최대 50), 작성자 닉네임(public_profiles)과 `is_mine`(내 리뷰 여부)·`has_incentive` 포함.

#### `facility_review_by_id(p_review) → TABLE(..., is_mine, visit_no, has_incentive)` [SD]
- 후기 단건 조회(행 모양은 `facility_reviews_of` 와 동일) — `review_comment` 알림 딥링크용. visible 만, `visit_no` 는 목록과 동일하게 형제 시설 범위에서 계산.

#### `facility_sibling_ids(p_id) → uuid[]` [INV]
- 같은 장소인데 별도 행으로 등록된 **형제 시설**을 모아 준다 — 50m 이내이면서 (이름 동일 | 전화 동일 | 이름 포함 관계) 인 것들. 후기·업체 매칭·QR 공유가 전부 이 배열을 기준으로 판정한다.
- 이 함수만 `SECURITY INVOKER` 다. `facilities` 는 전체 공개 SELECT 라 우회할 RLS 가 없고, definer 로 만들면 호출자 권한과 무관하게 도는 통로가 하나 더 생긴다.

#### `review_owner_switch_hint(p_review) → boolean` [SD]
- "이 후기, 사장님 계정으로 답글 다시겠어요?" 힌트용. 지금 **개인 모드**인데 승인 업체를 갖고 있고 그 업체가 후기 대상 시설(형제 포함)의 주인일 때만 true.

### 7.7. 채팅·디바이스

#### `start_direct_chat(p_other) → uuid` [SD] (**authenticated 전용** EXECUTE)
1. 로그인/자기자신 금지/상대 active 검증(각 P0001: `not_authenticated`, `invalid_target`, `user_not_found`).
2. `canonical_key = 'direct:작은uuid:큰uuid'` 로 방을 결정적으로 찾거나 생성(`on conflict do nothing` + 재조회로 경쟁 안전).
3. 두 사용자의 멤버십 누락분 보강 후 room id 반환. 1:1 방 중복 생성 불가 보장.

#### `delete_my_chat_message(p_message) → void` [SD] (**authenticated 전용**)
- 내 메시지만 소프트 삭제(`is_deleted=true`) — chat_messages UPDATE RLS 가 admin 전용이라 정의자 RPC 로만 가능. 타인 메시지는 P0001 거부.
- 부수효과: 아직 안 읽은 멤버의 `unread_chat_count` -1 보정, 방 미리보기(last_message_*)가 이 메시지면 다음 최신 비삭제 메시지로 갱신(없으면 '삭제된 메시지').

#### `register_device_token(p_token, p_platform, p_device_name?) → void` [SD] (**authenticated 전용**)
- 로그인 필수, 토큰 10자 미만 거부(`invalid_token` P0001). `device_tokens` 를 token 유니크로 upsert — **다른 계정이 쓰던 토큰이면 현 사용자로 소유권 이전**, `is_active=true`, failure_count 리셋.

#### `leave_chat_room(p_room) → void` [SD]
- `left_at` 을 찍고 읽음 포인터를 방 끝으로 밀어 안읽음을 0으로 만든다. **고객센터(`admin_inquiry`) 방은 나갈 수 없다.** 멤버가 아니면 `not_a_member`.
- 나간 방에는 아무도 새 메시지를 못 넣는다 — `trg_chat_messages_block_left`(§8.3)가 막는다.

#### `release_device_token(p_token) → void` [SD]
- 로그아웃 시 본인 기기 토큰 비활성화. **소유자 행만** 끄고, 남의 토큰을 지정해도 0행 갱신으로 조용히 끝난다 — 오류를 내면 "이 토큰이 누구 것인지" 를 확인해 주는 열거 통로가 된다.

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
- `admin_room_messages(p_room, p_limit=200) → TABLE` — 방 전체 메시지(삭제분 포함, 오래된 순, 최대 500) + 발신자 닉네임. 신고 상세의 '대화 내역' 진입용.
- `admin_list_reports(p_status='open', ...)` — 'open'=submitted+reviewing 묶음 조회.
- `admin_set_report_status(p_report, p_status)` — submitted/reviewing/resolved/dismissed 만, reviewed_by/at 기록 + admin_logs.
- `admin_get_report_target(p_report) → json` — 신고 대상(post/comment/user/chat_message)의 실제 내용 스냅샷 반환, 대상 소실 시 `{kind, exists:false}`. chat_message 는 `room_id` 포함(대화 내역 진입용).
- `admin_list_inquiries()` — 고객센터(admin_inquiry) 방 목록 + 문의자 + 마지막 메시지.
- `admin_join_inquiry(p_room)` — admin_inquiry 방인지 검증(P0001 `not_inquiry_room`) 후 관리자를 멤버로 추가.
- `admin_list_logs(p_limit=100, p_offset=0)` — 감사 로그 조회(최대 200).
- `admin_create_facility_share_link(p_facility, p_days=365) → TABLE(token, expires_at)` — 매장 QR 미리보기 공유 링크 발급(0028 §3). 같은 시설의 유효 링크가 있으면 **그 토큰을 재사용**(재호출로 기존 인쇄 QR 이 무효화되지 않게). 시설 미존재 시 `facility not found`.
- `admin_revoke_share_link(p_token) → boolean` — 링크 회수(오배포·유출 대응). 회수분은 share-view 가 404 로 응답.
- `admin_create_starter_share_link(p_business, p_days=365)` — 스타터 키트 QR 발급(0028 §1.3). **승인 업체 + `sales`/`production` 허가 승인** 둘 다 있어야 한다(`starter_license_required`). 유효 링크 재사용.
- `admin_broadcast_system_notice(p_title, p_body)` — 전체 공지를 `system_notice` 알림으로 일괄 INSERT. **정지·휴면 회원도 받는다**(약관 개정 고지는 이용 중지와 무관하게 도달해야 한다) — 제외 대상은 `deleted` 뿐. 제목 80자·본문 1000자 상한.
- `admin_ops_metrics() → json` — 운영 원가·활동 지표. SMS 9원/AI 20원 단가를 넣어 사진 검증·전화 인증 건수로 비용을 추정하고, 리프레시 토큰·메시지·댓글·글·하트를 합쳐 활성 사용자를 KST 기준 일자로 집계한다.
- `admin_photo_verification_failures(p_limit=50, p_offset=0)` — 사진 검증 **실패분**만 최신순(최대 200). fail_reason·ai_reason·지역일치·매칭점수·purpose 를 함께 준다 — AI 게이트 오탐률을 눈으로 재는 창구(펫 신원 섀도 운영).
- `admin_location_usage_logs(p_user, ...)` — 특정 사용자의 위치 이용·제공 기록 열람(위치정보법 §16 대응, §8.10 이 쌓는 것).
- `admin_ops_alarms(p_limit=50, p_offset=0)` — 발사된 운영 알람 이력(§3.8 `app.ops_alarms`). 푸시를 못 받았거나 지웠을 때 되짚는 창구다 — 알람의 1차 경로가 푸시라서 이 조회가 없으면 파이프라인이 죽었을 때 알람 자체가 사라진다.
- `admin_client_errors(p_where?, ...)` / `admin_client_error_summary(p_hours=24)` — 클라이언트 오류 원본 조회와 지점(`where_key`)별 집계(건수·영향 사용자 수·마지막 발생). 수집은 `record_client_error`(§7.12).
- `admin_list_business_applications(p_status?, p_track?, p_auto_only?, ...)` / `admin_set_business_status(p_user, p_status, p_reason?)` — 업체 신청 심사 큐와 승인/거절. 거절에는 **사유가 필수**(`reason_required`), 같은 상태로의 재설정은 `no_change` 로 막는다(감사 로그 오염 방지).
- `admin_list_business_licenses(p_status?, ...)` / `admin_review_business_license(p_license, p_status, p_reason?)` — 영업 허가증 심사. 승인은 **업체 프로필이 이미 approved 여야** 가능하다 — 허가만 먼저 통과해 자격이 앞서 나가는 걸 막는다.
- `admin_set_match_rule(p_key, p_weight?, p_enabled?, p_params?)` — 업체 자동매칭 가중치 조정(`business_match_rules`). before/after 를 `admin_logs` 에 남긴다 — 매칭 결과가 바뀌었을 때 "언제 무엇을 돌렸는지" 가 유일한 단서라서.

### 7.9.1. 공유 뷰어 RPC (모두 [SD][svc] — `share-view` Edge Function 전용, anon/authenticated EXECUTE 없음)

- `share_view_load(p_token) → jsonb` — 링크 검증(`not_found`/`expired`/`ok`) + kind 별 본문 조회 + 계측(view_count 원자 증가, funnel `share_view`)을 단일 왕복으로. `facility_preview` 는 시설 요약 + **인증 업체 대표 사진·영업시간**(형제 시설 범위 승인 업체 lateral, 콜드스타트 완화) + 최근 후기 3건(visible 만, `has_incentive`·사진 최대 2장 포함). `care_report` 는 리포트(pet_label·kind·photos·body·note·업체 상호) 반환 — 뷰어가 미용/돌봄 제목·알림장 필드(식사·배변 등)를 분기 렌더. app 스키마가 PostgREST 미노출이라 Edge Function 도 이 RPC 를 경유한다.
- `share_view_click(p_token) → boolean` — 유효 링크일 때만 funnel `store_click` 기록(스토어 302 직전 호출).

### 7.10. 업체 계정 (Business)

설계 정본은 pmdb `0025.md`·`0028.md`. `business_profiles` 는 RLS 가 SELECT 하나뿐이라(§9) 등록·수정·승인이 전부 여기를 지난다.

#### `apply_business_profile(p_user, p_b_no, ...) → jsonb` [SD][svc]
- 업체 신청 접수 + **자동 매칭 채점**. `apply-business` Edge Function 이 국세청 상태 조회를 마친 뒤 호출한다(그래서 svc 전용).
- `business_match_rules` 의 규칙별 가중치(전화 일치, 상호 유사도 상/중, 지역 일치, 주소 유사도, 업종 일치)를 합산해 임계값과 비교 → 자동 승인 / 심사 대기(`track`) 로 갈린다. 동점 후보가 여럿이면 자동 승인하지 않는다.
- 규칙은 DB 값이라 배포 없이 조정 가능하고, 조정 이력은 `admin_set_match_rule` 이 남긴다.

#### `apply_business_license(p_type, p_license_no, p_document_path) → uuid` [SD]
- 영업 허가증 제출(`grooming`/`boarding`/`sales`/`production` 등 `app.biz_license_type`). **업체 프로필이 pending 또는 approved 일 때만**(`biz_profile_required`), 허가번호 4–40자, 그리고 **문서 경로가 `<본인 uid>/` 로 시작해야 한다** — 남의 폴더 경로를 적어 증빙을 가로채는 걸 막는다.

#### `my_business_licenses() → TABLE` [SD]
- 본인 허가 신청 목록(상태·거절사유·심사일시).

#### `update_my_business_info(p_storefront_name?, p_phone?, p_email?, p_hours?)` / `set_my_business_photo(p_url, p_align_y)` [SD]
- 둘 다 `app.assert_business_actor()` — **업체 모드로 전환한 상태**여야 하고 프로필이 approved 여야 한다. NULL 인자는 기존 값 유지(`coalesce`). 영업시간 문자열은 100자 상한.
- 사진은 `business_profiles` 와 매칭된 `facilities` 행에 **동시 반영**된다 — 지도에서 보는 대표 사진이 곧 이 값이라 한쪽만 바뀌면 화면이 갈라진다. `align_y` 는 −1..1 로 클램프.

#### `business_doc_purge_take(p_limit=200)` / `business_doc_purge_done(p_ids)` [SD][svc]
- 증빙 서류 파기 큐의 인출/완료 표시. `purge-business-docs` Edge Function 이 크론에 깨어나 호출한다.
- `take` 는 꺼내기 전에 **아직 살아 있는 신청이 참조하는 경로를 큐에서 지운다** — 재신청으로 같은 파일을 다시 쓰게 된 경우 파기하면 안 되기 때문. 한 번에 최대 500건.

### 7.11. 케어 리포트·접종 (0028)

미용/돌봄 업체가 보호자에게 보내는 알림장. 수신자는 **회원이 아닐 수 있어** 전화번호를 HMAC(`app.phone_hmac`)으로만 들고 있다가, 나중에 그 번호로 가입하면 본인 것으로 끌어간다.

- `create_care_thread(p_pet_label, p_recipient_phone?) → uuid` [SD] — 돌봄(호텔) 스레드 개설. `app.has_license('boarding')` 필수(`license_required`), 라벨 50자 이내.
- `create_boarding_report(p_thread, p_photos, p_body, p_note?)` [SD] — 스레드에 알림장 추가(사진 최대 4장, 식사·배변 등 구조화 `body`). 본인 스레드만(`thread_not_found`).
- `create_care_report(p_pet_label, p_photos, p_note?, p_recipient_phone?)` [SD] — 미용 단건 리포트. `has_license('grooming')` 필수, 사진 1–4장.
- `my_received_care_reports(p_limit, p_offset)` [SD] — **보호자 쪽** 조회. `claim_care_reports` 로 끌어온 내 리포트 목록(보낸 업체 상호 포함).
- `my_care_threads(...)` / `my_care_reports(...)` / `care_thread_reports(p_thread, ...)` [SD] — 업체 쪽 목록 조회. 스레드 목록은 리포트 수·대표 사진·보관 기한 초과 여부(`app.care_config.boarding_archive_days`)를 함께 준다.
- `claim_care_reports() → integer` [SD] — **가입 후 끌어오기**. 내 전화번호 HMAC 과 일치하는 미청구 리포트를 전부 내 것으로 표시하고, 표시하는 즉시 **HMAC 을 NULL 로 지운다**(더 이상 필요 없는 식별자는 남기지 않는다). 건수만큼 `system_notice` 알림. 자기 업체가 보낸 건 제외.
- 청구되지 않은 채 링크가 만료되거나 30일이 지난 HMAC 은 `care-report-hmac-purge` 크론이 지운다(§3).

**접종 일정** — `app.vaccination_events` 를 다루는 세 개. 전부 **보호자 검증**(`not_guardian`)을 먼저 한다.
- `set_vaccination_schedule(p_pet, p_events jsonb, p_source?)` [SD] — 미완료 일정을 지우고 다시 깔아 준다(최대 40건, `p_source` 는 `onboarding`/`manage`). 완료(`done_at`) 표시된 건은 보존한다.
- `my_vaccination_events(p_pet)` [SD] — 예정일 순 조회.
- `set_vaccination_done(p_event, p_done) → boolean` [SD] — 완료/해제 토글. 보호자가 아니면 0행 갱신 → false.
- 알림은 크론 `vaccine-reminder-sweep` 이 KST 기준 오늘·내일 예정건에 대해 보낸다(§3).

### 7.12. 기타

#### `record_client_error(p_where, p_message, p_stack?, p_platform?, p_release?, p_extra?) → void` [SD] (**anon 포함 공개**)
- 클라이언트 오류 수집(0031). 공개 함수라 방어가 본체다:
  - 필수 인자가 비면 **조용히 return** — 오류 보고가 예외를 던지면 원래 오류를 덮는다.
  - 레이트리밋 2단: 개별 30/분 + 익명 전역 300/분. 1단을 통과한 요청만 전역에 세므로 한 소스가 예산을 독식하지 못한다.
  - 익명 식별은 **`cf-connecting-ip` 만** 쓴다. `x-forwarded-for` 는 맨 왼쪽이 클라이언트 주장값이라 위조하면 버킷이 무한 생성된다. 헤더가 없으면 폴백하지 않고 공용 버킷으로 떨어뜨린다 — **폴백이 곧 우회로**다.
  - 과대 페이로드는 버리지 않고 **잘린 사실과 앞부분을 남긴다**.
- 조회는 관리자 RPC(`admin_client_errors`, `admin_client_error_summary`).

#### `app.ops_alarm_sweep() → integer` [SD][cron]
- 5분마다 도는 운영 알람 스윕(§3.8). 다섯 가지를 본다 — ① 지점별 앱 오류 급증 ② 총량 급증 ③ 레이트리밋 계열별 다발 ④ 푸시 발송 실패 ⑤ 크론 실패 ⑥ 증빙 파기 적체. 발사는 `app.ops_alarm_fire()` 한 곳을 지나며 거기서 쿨다운을 판정한다.
- **지점별과 총량을 둘 다 보는 이유**: 지점별만 보면 서버가 죽어 모든 화면이 조금씩 실패하는 경우를 놓친다(지점별로는 임계 미달, 총량은 폭증). 총량만 보면 한 화면이 터진 걸 평상시 잡음에 묻는다.
- **쿨다운이 필요한 이유**: 급증은 몇 분간 이어진다. 5분마다 같은 알람이 오면 사람은 알림을 꺼 버리고, 그러면 관측 장치가 없는 것과 같아진다.
- 크론 조건은 `to_regclass('cron.job_run_details')` 로 존재를 먼저 확인한다 — **pg_cron 은 운영에만 있다.** pgTAP CI 는 `prelude + schema.sql`(= `-n public -n app` 덤프)만 복원하므로 cron 스키마가 없고, 그냥 참조하면 알람을 검증하려고 부르는 순간 함수가 통째로 터진다.
- 한계: **pg_cron 자체가 멈추면 이 스윕도 안 돈다.** 자기 자신의 부재는 감지할 수 없다.
- pgTAP: t21(12건).

#### `rls_auto_enable() → event_trigger` [SD]
- DDL 이벤트 트리거 함수: public 스키마에 `CREATE TABLE` 류가 실행되면 **자동으로 해당 테이블 RLS 를 활성화**. "RLS 켜는 걸 잊는" 실수 방지 가드레일. 이 함수를 실행하는 이벤트 트리거의 이름은 **`ensure_rls`**(ddl_command_end).

---

## 8. 트리거

비내부 트리거는 **77개** — public 76 + `app.business_licenses` 1. 정의 함수는 전부 `app` 스키마이고 고유 함수는 60개다(여러 테이블이 같은 함수를 공유한다: `tg_set_updated_at`, `tg_block_business_actor`, `tg_log_location_usage`, `comments_set_authored_as`).

공통 트리거 `tg_set_updated_at`(BEFORE UPDATE)은 13개 테이블에서 `updated_at := now()` 를 세팅한다 — applications, appointments, chat_messages, chat_room_members, device_tokens, notifications, pets, posts, reports, users(이름 `trg_<테이블>_updated`), notification_preferences·review_category_counts(`trg_..._upd`), `app.business_licenses`(`trg_business_licenses_updated`). **`business_profiles` 에는 없다** — `updated_at` 컬럼은 있지만 갱신은 RPC 가 직접 한다.

나머지를 테이블별로 설명한다.

### 8.1. `applications` (지원)

| 트리거 | 시점 | 함수 | 동작 |
|---|---|---|---|
| `trg_applications_block_insert` | BEFORE INSERT | `tg_applications_block_insert` | 지원 가능성 종합 검증 |
| `trg_applications_immutable_offer` | BEFORE UPDATE | `tg_applications_immutable_offer` | `offered_pet_id` 변경 금지 |
| `trg_applications_on_accept` | AFTER UPDATE | `tg_applications_on_accept` | 수락 시 매칭 확정 처리 |
| `trg_notify_application` | AFTER INSERT | `tg_notify_application` | 글 작성자에게 `post_application` 알림 |
| `trg_notify_application_accepted` | AFTER UPDATE | `tg_notify_application_accepted` | 수락 시 지원자에게 `application_accepted` 알림 |
| `trg_applications_block_business` | BEFORE INSERT | `applications_block_business_mode` | 지원자의 `users.active_mode='business'` 면 `business_mode_not_allowed` |
| `trg_applications_block_business_update` | BEFORE UPDATE | `tg_block_business_actor` | 업데이트 시 `app.assert_personal_actor()` — 업체 모드 세션의 상태 변경 차단 |

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
| `trg_appointments_block_business` | BEFORE INSERT/UPDATE | `tg_block_business_actor` | `app.assert_personal_actor()` — 업체 모드로는 약속 생성·변경 불가 |

- **after_update**:
  - `scheduled→completed`: 게시글 `matched→completed`, application `accepted→completed`. 카테고리가 **give_away(분양)** 면 글의 펫 보호자 전원 삭제 후 지원자를 owner 로 등록 + `primary_guardian_id` 이전. **adoption(입양)** 이면 `offered_pet` 을 글 작성자에게 동일 방식으로 이전. → **소유권 이전이 DB 에서 원자적으로 일어남**.
  - `scheduled→cancelled`: 게시글 `matched→recruiting` 복귀, application `accepted→cancelled`.

### 8.3. `chat_messages` / `chat_room_members`

- `trg_chat_messages_after_insert` (AFTER INSERT): 미리보기(`content` 100자 또는 '[사진]')로 방의 `last_message_*` 갱신 → 발신자 제외 멤버들의 `users.unread_chat_count+1` → 멤버별 `chat_message` 알림 INSERT(제목=발신자 닉네임, 본문=미리보기) — 이 알림 INSERT 가 다시 푸시 웹훅을 유발.
- `trg_chat_messages_soft_delete_ts` (BEFORE UPDATE): `is_deleted` false→true 시 `deleted_at := now()`.
- `trg_chat_messages_after_softdelete` (AFTER UPDATE): 삭제된 메시지가 방의 마지막 메시지면 미리보기를 "삭제된 메시지입니다." 로 교체.
- `chat_messages_block_blocked` (BEFORE INSERT): 방의 **다른 멤버와 차단 관계**(방향 무관)면 "차단된 상대와는 메시지를 주고받을 수 없어요" 예외. 이 트리거는 `user_blocks` 를 직접 조인한다 — `app.is_blocked_pair()` 도입 전 정의라 조건이 중복돼 있다(0032 §2 의 정리 대상이었으나 동작이 동일해 그대로 뒀다).
- `trg_chat_messages_block_left` (BEFORE INSERT): 방에 `left_at` 이 찍힌 멤버가 하나라도 있으면 "상대가 채팅방을 나가 메시지를 보낼 수 없어요" 예외.
- `trg_chat_members_read` (BEFORE UPDATE, chat_room_members): `last_read_message_id` 변경 시 ① 그 메시지가 **같은 방** 메시지인지 검증(아니면 예외) ② (old, new] 구간의 상대 발신·미삭제 메시지 수만큼 `users.unread_chat_count` 를 감산(음수 방지). `(created_at, id)` 튜플 비교로 동시각 메시지도 정확히 처리.

### 8.4. `comments`

- `trg_comments_count` (AFTER INSERT/UPDATE): INSERT 시 `posts.comment_count+1`(미삭제일 때), soft delete 전환 시 -1, 복원 시 +1.
- `trg_comments_soft_delete_ts` (BEFORE UPDATE): 삭제 전환 시 `deleted_at` 세팅.
- `trg_notify_comment` (AFTER INSERT): 글 작성자에게 `post_comment` 알림(본인 댓글 제외, 실패 무시).
- `trg_comments_authored_as` (BEFORE INSERT, `comments_set_authored_as`): 작성자의 `users.active_mode` 를 `authored_as` 로 스탬프(NULL 이면 `personal`). 나중에 모드를 바꿔도 **작성 시점의 정체성이 고정**된다.
- `trg_comments_block_check` (BEFORE INSERT, 2026-08-04 신설): 글 작성자와 차단 관계(`app.is_blocked_pair`)면 예외. 종전에는 차단해도 상대 글에 댓글이 달렸다(0032 §2).
- `trg_audit_comments` (AFTER UPDATE): **관리자가** 삭제로 전환한 경우에만 `admin_logs` 에 `delete_comment` 기록.

### 8.5. `posts`

- `trg_posts_check_write` (BEFORE INSERT, `tg_posts_check_write`) — **게시글 작성 자격의 최종 관문**:
  1. 작성자 존재 검증.
  2. `walk_together/walk_proxy/care/give_away` 는 `user_type='pet_owner'` 만.
  3. give_away 는 본인이 owner 인 active 펫 보유 필수; walk/care 는 보호 중인 active 펫 보유 필수.
  4. walk/care 는 `scheduled_at` 필수, give_away/adoption 은 `scheduled_at` 금지.
  5. 사진 필요 카테고리는 `image_url` 필수 + GUC `app.photo_token` 필수. `photo_verifications` 에서 (본인·purpose='post'·pet 지정·result='pass'·ai_pass·region_matched·미소비·미만료·**image_url 일치**) 조건으로 조회 — 실패 시 "유효하지 않거나 만료된 사진 검증입니다".
  6. 통과 시 토큰 `consumed_at` 소비(1회용), `photo_verification_id`/`ai_pet_species`/`is_pet_verified` 를 게시글에 스탬프.
- `trg_posts_set_region` (BEFORE INSERT): 동네 인증 게이트(미인증/만료 30일 거부, 관리자 예외) + region_code 미지정 시 작성자의 region_code 복사, `display_address` 미지정 시 작성자 주소의 **마지막 토큰(동 이름)** 만 노출용으로 저장. **업체 모드 글(news)은 게이트 면제** — 대신 승인 업체만 허용하고 지역/동은 사업장 주소(`business_region_code`·지번 동) 기준으로 스탬프.
- `trg_posts_block_trader` (BEFORE INSERT / UPDATE OF category, `tg_posts_block_trader`) — **영업자 공통 차단선(0028 §2)**: 승인된 `business_profiles` 보유 계정은 `adoption`/`give_away` 작성·카테고리 변경 불가. 활성 모드 무관(개인 모드 전환 우회 봉쇄) — 업체 모드는 `trg_posts_authored_as`(알파벳순 선행)가 이미 news 로 강제. 미인증 영업자는 운영 정책(신고·모니터링) 담당. 적용 전 기존 위반 2건은 grandfather. pgTAP: t08.
- `trg_posts_deleted_at` (BEFORE INSERT/UPDATE): `visibility_status like 'deleted_%'` 면 deleted_at 세팅, 아니면 NULL 로 클리어.
- `trg_posts_validate_transition` (BEFORE UPDATE): 상태기계 강제 — visibility: `visible→hidden_by_user|hidden_by_admin|deleted_by_user|deleted_by_admin`, `hidden_by_user→visible|deleted_by_user`, `hidden_by_admin→visible|deleted_by_admin`, deleted_* 는 terminal. progress: `recruiting→matched|cancelled`, `matched→completed|recruiting`, completed/cancelled 는 terminal. 위반 시 예외.
- `trg_posts_authored_as` (BEFORE INSERT, `posts_set_authored_as`): 작성 시점의 `active_mode` 를 `authored_as` 로 고정하고, 업체 모드면 카테고리를 `news` 로 강제한다. 이름이 알파벳순으로 앞서 `trg_posts_block_trader` 보다 **먼저** 돈다.
- `trg_audit_posts` (AFTER UPDATE): 관리자가 hidden_by_admin/deleted_by_admin 으로 바꿀 때 `admin_logs`(hide_post/delete_post) 기록.
- `log_location_usage` (AFTER INSERT, `tg_log_location_usage('post')`, **WHEN `actual_lat` 또는 `actual_lng` 가 NOT NULL**): 위치정보법 §16 이용·제공 기록을 `app.location_usage_logs` 에 남긴다(§8.10).

### 8.6. `post_hearts` / `post_views` / `post_pets`

- `trg_post_hearts_count` (AFTER INSERT/DELETE): `posts.heart_count` ±1 (음수 방지).
- `trg_post_views_count` (AFTER INSERT): `posts.view_count+1`.
- `trg_post_hearts_block_check` (BEFORE INSERT, 2026-08-04 신설): 글 작성자와 차단 관계면 예외 — 좋아요도 접촉이다(0032 §2).
- `trg_post_hearts_recall` (AFTER DELETE): 좋아요를 취소하면 아직 **안 읽은** `post_heart` 알림을 지운다. 읽은 알림은 남긴다(이미 본 사실을 지우지 않는다).
- `trg_post_pets_giveaway_limit` (BEFORE INSERT): 글 작성자가 그 펫의 보호자가 아니면 차단("본인이 보호 중인 반려동물만 연결 가능"); give_away 글은 **owner 역할 + 정확히 1마리**만 연결 가능.
- `trg_notify_pet_in_post` (AFTER INSERT): 그 펫의 **다른 공동보호자들**에게 `pet_in_post` 알림. 같은 글에 대해 중복 발송하지 않는다.
- `trg_post_pets_bump_verify_count` (AFTER INSERT): 글 카테고리가 `walk_together/walk_proxy/care/give_away` 면 `pets.verify_post_count+1` — 사진 검증을 거친 글에 등장한 횟수로, 펫 신뢰 표시의 재료.

> `post_pets` 는 2026-08-03 부터 클라이언트 직접 쓰기가 **REVOKE** 돼 있다(0032 §3). 위 트리거들은 이제 RPC 경유 INSERT 에만 걸린다. `pet_guardian_invites` 도 2026-08-04 부터 INSERT 가 회수돼, 아래 초대 트리거들은 `invite-guardian`(service_role) 경유로만 돈다.

### 8.7. `pets` / `pet_guardians` / `pet_guardian_invites`

- `trg_pets_after_insert`: 펫 등록 시 `primary_guardian_id` 를 owner 보호자로 자동 등록 + 등록자 `user_type` 을 `pet_owner` 로 자동 승격.
- `trg_pet_guardians_owner_self_remove` (BEFORE DELETE): 사용자 컨텍스트(`app.uid()` 존재)에서 owner 본인 행 직접 삭제 금지("먼저 소유권을 이전하세요") — 시스템(분양 이전)은 우회 가능.
- `trg_pgi_resolve_invitee` (BEFORE INSERT, invites): `invitee_user_id` 가 없고 전화번호만 있으면 가입자 조회해 자동 연결. resolve 후 최종 invitee 가 inviter 본인이면 `self_invite` 예외(자기 초대 차단 — 직접 INSERT·service_role 포함 전 경로 백스톱).
- `trg_notify_guardian_invite` (AFTER INSERT): `kind='invite'` 이고 수신자 확정 시 `guardian_invite` 알림("OO님이 △△의 공동보호자로 초대했어요").
- `trg_pgi_respond` (BEFORE UPDATE): `pending→accepted` 시 — invite 면 초대받은 사람이, request 면 신청자가 보호자가 됨(미확정이면 예외). **그 사람이 해당 펫 글의 진행 중 약속 지원자면 수락 차단**(이해충돌 방지). `pet_guardians` 에 `co_guardian` 으로 INSERT(중복 무시), `responded_at` 세팅. `declined/expired` 도 responded_at 기록.

### 8.8. `users`

- `trg_users_after_insert`: ① `notification_preferences` 기본행 ② admin 이 아니면 고객센터(`admin_inquiry`) 채팅방 + 본인 멤버십 자동 생성(`canonical_key='admin_<uid>'`) ③ 내 전화번호로 걸려 있던 pending 보호자 초대에 `invitee_user_id` 연결 + 초대 알림 생성.
- `trg_users_owner_succession` (AFTER UPDATE): `active → inactive|suspended` 전이 시 **펫 소유권 승계** — owner 인 각 펫에 대해 가장 오래된 co_guardian 을 owner 로 승격(+`primary_guardian_id` 갱신); 후계자가 없으면 펫을 `deleted` 처리. 마지막에 떠나는 사용자의 보호자 행 전부 삭제. (self-remove 방지 트리거와의 충돌을 피하려고 먼저 co_guardian 으로 강등하는 순서 제어 포함.)

### 8.9. `reviews` / `review_category_counts` / `facility_reviews` / `notifications` / `reports` 등

- `trg_reviews_validate` (BEFORE INSERT): 약속 존재 + `status='completed'` 필수, reviewer/reviewee 가 정확히 약속 당사자 쌍(양방향)이어야 함, categories 배열 중복 금지.
- `trg_reviews_aggregate` (AFTER INSERT): 카테고리별로 `review_category_counts` upsert(+1) — 프로필의 "받은 평가" 집계.
- `trg_notify_review` (AFTER INSERT): 상대에게 `review_received` 알림.
- `trg_reviews_block_business` (BEFORE INSERT, `tg_block_business_actor`): `app.assert_personal_actor()` — 업체 모드로는 후기 작성 불가.
- `trg_reviews_grant_pet_trust` (AFTER INSERT): 후기가 달리면 그 약속을 `trust_awarded=true` 로 **한 번만** 표시하고(조건부 UPDATE 라 중복 지급이 안 된다), 성공했을 때만 그 글에 연결된 펫들의 `trust_score+1`.
- `facility_reviews_aggs` (AFTER INSERT/UPDATE/DELETE, `app.tg_facility_review_aggs`): 내부에서 `app.refresh_facility_aggs()` 를 호출해 시설의 `review_count`/`avg_rating`(소수1자리) 재계산.
- `trg_notify_facility_review` (AFTER INSERT, facility_reviews): 후기가 달린 시설을 **승인된 업체 계정**이 갖고 있으면 그 사장에게 `facility_review_received` 알림. 대상 판정에 `public.facility_sibling_ids()` 를 써서 같은 장소의 중복 등록(형제 시설)까지 포괄한다.
- `trg_facility_review_recall` (AFTER UPDATE, facility_reviews): 후기가 `visible` 에서 벗어나면(숨김·삭제) 아직 **안 읽은** `facility_review_received` 알림을 회수(§8.10).
- `trg_frc_authored_as` / `trg_frc_soft_delete_ts` / `trg_notify_review_comment` (facility_review_comments): 각각 작성 모드 스탬프, soft delete 시각 세팅, 후기 작성자에게 `review_comment` 알림(본인 댓글 제외, **알림 실패는 삼킨다** — 댓글 자체는 남는다).
- `trg_pawings_recall` (AFTER DELETE, pawings): 팔로우를 끊으면 안 읽은 `pawing_follow` 알림 회수(§8.10).
- `trg_notifications_push` (AFTER INSERT, `app.on_notification_push`): `push_status='pending'` 이고 무음이 아니면 `app.push_config` 의 URL 로 `net.http_post`(헤더 `x-push-secret`) — Edge Function 즉시 기동.
- `trg_notifications_read_ts` (BEFORE UPDATE): 읽음 전환 시 `read_at` 세팅.
- `trg_notifications_unread_count` (AFTER INSERT/UPDATE): `users.unread_notification_count` 증감 캐시 유지.
- `trg_notifications_block_filter` (BEFORE INSERT, 2026-08-04 신설): 수신자와 행위자가 차단 관계면 **`NULL` 을 반환해 알림을 조용히 버린다**(예외가 아니다 — 알림 실패가 원 동작을 되돌리면 안 되므로). 알림 생성 지점이 10곳이 넘어 발신부마다 조건을 다는 대신 마지막 관문 한 곳에 뒀다(0032 §2).
- `trg_audit_reports` (AFTER UPDATE): 관리자의 신고 상태 변경을 `admin_logs`(update_report_status, before/after) 기록.

### 8.10. 가로지르는 두 패턴

**① 알림 회수(recall).** 원 행동을 되돌리면 **아직 안 읽은** 알림만 지운다 — `trg_post_hearts_recall`(좋아요 취소), `trg_pawings_recall`(팔로우 해제), `trg_facility_review_recall`(후기 숨김·삭제). 읽은 알림을 남기는 건 의도된 것이다: 이미 본 사실을 사후에 지우면 이용자 기록이 어긋난다. 회수는 `notifications` 를 **하드 삭제**하므로 `users.unread_notification_count` 와 어긋날 수 있다 — 보정은 `app.reconcile_unread_counts()`.

**② 위치 이용 기록.** 같은 함수 `app.tg_log_location_usage(purpose)` 가 세 테이블에 붙어 `app.location_usage_logs` 에 (user_id, purpose) 를 남긴다 — 위치정보법 §16 의 이용·제공사실 기록 의무를 DB 레벨에서 이행한다. purpose 는 트리거 인자로 주입된다.

| 테이블 | 시점 | WHEN | purpose |
|---|---|---|---|
| `location_verifications` | AFTER INSERT | 없음(항상) | 동네 인증 |
| `posts` | AFTER INSERT | `actual_lat` 또는 `actual_lng` NOT NULL | 게시글 |
| `photo_verifications` | AFTER INSERT | `shot_lat` 또는 `shot_lng` NOT NULL | 사진 검증 |

`WHEN` 절이 붙은 두 개는 **좌표가 실제로 저장될 때만** 기록한다 — 좌표 없이 지역코드만 쓰는 경로까지 위치 이용으로 세면 기록이 부풀려져 이용내역 열람이 오히려 부정확해진다.

또한 DB 수준 **이벤트 트리거** `ensure_rls`(ddl_command_end → `public.rls_auto_enable()`, §7.12)가 걸려 있어 public 에 새 테이블이 생기면 RLS 가 자동 활성화된다.

---

## 9. RLS 정책

public 스키마 **76개** + storage **7개** = 총 83개 정책(2026-08-04 실측).

> **무인자 헬퍼는 `(select …)` 로 감싼다**(2026-08-04, `20260804220000`). `app.uid()` 는
> 매 호출마다 `request.jwt.claims` 를 세 번 jsonb 로 파싱하고 `public.users` 를 조회하는데,
> RLS 조건에 맨몸으로 놓이면 **읽는 행마다** 그게 다시 돈다(플래너가 STABLE 함수를 그
> 자리에서 자동으로 끌어올리지 않는다). 스칼라 서브쿼리로 감싸면 InitPlan 이 되어 한 번만
> 평가된다 — 5만 행 기준 **1250ms → 6ms** 로 측정됐다.
>
> 감싼 것은 `app.uid()`·`app.is_admin()`·`app.uid_lite()` **77개 정책**. `app.is_pet_guardian(pet_id, …)`
> 처럼 **컬럼을 인자로 받는** 헬퍼는 행마다 값이 달라 감쌀 수 없다(15개 정책) — 그 경로는
> 헬퍼 안에서 다시 `app.uid()` 를 부르므로 행별 비용이 남아 있다.
>
> 새 정책을 쓸 때도 같은 규칙을 따를 것. Supabase 성능 린터는 `auth.uid()` 를 찾으므로
> 우리 `app.uid()` 는 **잡아 주지 않는다.** 전부 PERMISSIVE, 대상 롤은 public(storage 는 authenticated). 판별은 전적으로 `app.uid()` / `app.is_admin()` / `app.is_*` 헬퍼에 의존하므로 **JWT 없이(anon) 접근하면 `app.uid()=NULL` 이 되어 "내 것" 조건이 모두 false** 가 된다.

### 테이블별 요약

| 테이블 | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `admin_logs` | 관리자만 | — | — | — |
| `applications` | 지원자 본인 또는 글 관리자(`is_post_manager`) | 본인 명의만(`applicant_id=uid`) | 지원자 본인 또는 글 관리자 | — |
| `appointments` | 당사자(글 소유측/지원자) 또는 관리자 | — (트리거가 생성) | 당사자 또는 관리자 (WITH CHECK 동일) | — |
| `business_profiles` | **본인 행만**(`user_id=uid`) — 관리자도 REST 로는 못 본다 | — | — | — |
| `business_match_rules` | 관리자만 | — | — | — |
| `chat_message_deletions` | 본인 것만 | 본인 명의만 | — | — |
| `chat_messages` | 방 멤버 또는 관리자 | 본인 발신 + 방 멤버일 때만 | **관리자만** (일반 사용자는 메시지 수정/삭제 불가 — 관리자 RPC 로만 soft delete) | — |
| `chat_room_members` | 본인 행, 같은 방 멤버, 관리자 | 본인 등록 또는 관리자 | 본인 행만(읽음 포인터 갱신용) | — |
| `chat_rooms` | 방 멤버 또는 관리자 | 로그인 사용자 누구나(`uid is not null`) | 관리자만 | — |
| `comments` | 미삭제 댓글 전체 또는 관리자(삭제 포함), **차단 상대 댓글 제외**(2026-08-05) | 본인 명의만 | 본인 또는 관리자 | — |
| `device_tokens` | ALL: 본인 것만 (SELECT/INSERT/UPDATE/DELETE 일괄) | | | |
| `facilities` | 전체 공개 | — | — | — |
| `facility_cache` | 전체 공개 | 관리자 | 관리자 | 관리자 |
| `facility_review_comments` | 미삭제 전체 또는 관리자(삭제 포함) | 본인 명의만 | 본인 또는 관리자 | — |
| `facility_reviews` | visible 리뷰 전체 + 본인 리뷰(숨김 포함) | — (RPC 전용) | — | — |
| `location_verifications` | 본인 또는 관리자 | 본인 명의만 (실제로는 svc RPC 사용) | — | — |
| `notification_preferences` | ALL: 본인 것만 | | | |
| `notifications` | 본인 또는 관리자 | **관리자만** (일반 알림은 트리거/SECURITY DEFINER 가 생성) | 본인 또는 관리자(읽음 처리) | — |
| `pawings` | 전체 공개(팔로우 관계는 공개 정보) | 본인이 follower 일 때만 | — | 본인이 follower 일 때만(언팔) |
| `pet_guardian_invites` | 초대자/피초대자/펫 owner/관리자 | **REVOKE(2026-08-04)** — 정책은 남아 있으나 그랜트가 없어 도달 불가 | 관리자, invite 는 피초대자, request 는 펫 owner (응답 권한) | — |
| `pet_guardians` | 그 펫의 보호자(아무 역할) 또는 관리자 | 펫 owner 또는 관리자 | 펫 owner 또는 관리자 | 펫 owner 또는 관리자 |
| `pet_identity_frames` | 그 펫의 보호자 또는 관리자만 (신원 프레임은 비공개) | — | — | — |
| `pets` | `pet_status<>'deleted'` 전체 공개 + 삭제펫은 보호자/관리자만 | `primary_guardian_id=uid` 본인 명의만 | 펫 owner 또는 관리자 | — |
| `post_hearts` | 전체 공개 | 본인 명의만 | — | 본인 것만(하트 취소) |
| `post_pets` | 글이 visible 이거나 글 작성자/관리자 | 글 작성자만 | — | 글 작성자 또는 관리자 |
| `post_views` | 관리자만 | 본인 명의만(조회 기록) | — | — |
| `posts` | visible 전체 + hidden_by_user 는 작성자만 + 관리자 전부, **차단 상대 글 제외**(2026-08-05) | 본인 명의만 | 본인 또는 관리자 | **관리자만**(하드 삭제) |
| `reports` | 신고자 본인 또는 관리자 | 본인 명의만 | 관리자만 | — |
| `review_category_counts` | 전체 공개 | — (트리거가 관리) | — | — |
| `reviews` | 전체 공개 | reviewer 본인만(+ 트리거 검증) | — | — |
| `user_blocks` | 차단한 본인만 | 본인 명의만 | — | 본인 것만(차단 해제) |
| `users` | `status<>'suspended'` 전체 + 본인 + 관리자 (정지 계정은 타인에게 숨김) | — (가입은 signup_user RPC) | 본인 또는 관리자 (단, 컬럼 권한으로 갱신 가능 컬럼 제한 — §10) | — |

설계 특징:
- **삭제는 대부분 soft delete**: comments/chat_messages/posts/facility_reviews 는 DELETE 정책이 없거나 관리자 전용이고, `is_deleted`/`visibility_status` 갱신으로 처리한다.
- **정지 계정 처리**: `users_select` 가 suspended 를 숨기고, `app.uid()` 자체가 active 만 인정하므로 정지 즉시 모든 권한이 소멸한다.
- INSERT 가 막힌 테이블(appointments, notifications, facility_reviews 등)은 SECURITY DEFINER RPC/트리거만 쓸 수 있다.
- **`business_profiles` 는 정책이 SELECT 하나뿐이다** — 업체 정보를 남에게 보여 주는 건 테이블이 아니라 SECURITY DEFINER 뷰(`public_profiles`, `v_post_feed`, `v_chat_rooms`, `v_comment_feed`)이고, 등록·수정·승인은 전부 RPC(`apply_business_profile`, `update_my_business_info`, `set_my_business_photo`, `admin_set_business_status`)다. 관리자 조회조차 RPC(`admin_list_business_applications`)를 거친다 — 컬럼 권한 때문에 테이블 직접 노출을 피한 것(§10).

### storage.objects 정책 7개

| 정책 | 대상 | 내용 |
|---|---|---|
| `media owner insert` | authenticated INSERT | `bucket_id='media'` 이고 **경로 첫 폴더명 = 본인 uid** 일 때만 업로드 (`storage.foldername(name)[1] = app.uid()::text`) |
| `media owner update` | authenticated UPDATE | 동일 조건 — 자기 폴더 안 객체만 |
| `media owner delete` | authenticated DELETE | 동일 조건 — 자기 폴더 안 객체만 |
| `media lite review insert` | authenticated INSERT | 자기 폴더의 **두 번째 칸이 `facility_review` 일 때만**, 판별은 `app.uid_lite()`. 간이 회원용 좁은 통로(2026-08-04, 0032 §1.1) |
| `business docs owner insert` | authenticated INSERT | `bucket_id='business-docs'` + 자기 폴더 |
| `business docs owner select` | authenticated SELECT | 자기 폴더 안 객체만 읽기 |
| `business docs admin select` | authenticated SELECT | `app.is_admin()` — 심사용 전체 열람 |

- `media` 경로 규약은 `media/<user_id>/<category>/...`, 쓰기·수정·삭제는 자기 폴더로 한정된다. **`media` 에는 SELECT 정책이 없다** — 공개 버킷이라 public URL 로 읽는다(§11).
- `business-docs` 는 비공개 버킷이라 SELECT 정책이 실제 열람 통제로 작동한다 — 본인과 관리자만.
- **`business-docs` 에는 DELETE 정책이 없다.** 증빙 파기는 사용자가 아니라 `purge-business-docs` Edge Function 이 service_role 로 수행한다(§3.8 큐 + pg_cron).

---

## 10. 컬럼 권한 및 함수 실행 권한

RLS 는 "어느 **행**을 볼 수 있나" 만 정한다. "그 행의 어느 **컬럼**까지 볼 수 있나" 는
컬럼 단위 GRANT 가 정하고, `users`·`posts`·`pets` 세 테이블이 그걸 쓴다. 아래는
2026-08-04 `information_schema.column_privileges` 실측이다.

### 10.1. users — 컬럼 단위 SELECT/UPDATE (핵심 프라이버시 장치)

`users` 는 **테이블 수준 SELECT/UPDATE/INSERT 권한이 회수**되어 있고(authenticated 에는 REFERENCES/TRIGGER/TRUNCATE 만 잔존), 필요한 컬럼에만 컬럼 단위 GRANT 가 있다.

| 권한 | anon | authenticated |
|---|---|---|
| SELECT | id, nickname, user_type, profile_image_url, profile_image_thumbnail_url, address, is_location_verified, created_at | 왼쪽 8개 + **last_verified_at, active_mode** |
| UPDATE | — | nickname, profile_image_url, profile_image_thumbnail_url, profile_image_mime_type, profile_image_file_size, push_enabled |

- **`username`(로그인 ID), `phone`, `password_hash`, `latitude`/`longitude`(정확 좌표), `token_version`, `status`, `region_code`, 미읽음 카운트 등은 SELECT 불가.** username 은 관리자 RPC(`admin_list_users`)와 SECURITY DEFINER 함수 내부에서만 닿는다.
- 일반 사용자가 UPDATE 할 수 있는 건 닉네임/프로필 이미지/푸시 on-off 뿐이다. `user_type`·`status`·`is_location_verified`·`active_mode` 는 전부 RPC/트리거 전용 — 특히 `active_mode` 는 SELECT 는 되지만 UPDATE 는 안 된다(`switch_account_mode` 가 승인 여부를 확인한 뒤에만 바꾼다).

### 10.2. posts / pets — 컬럼 단위 권한

`posts` 도 테이블 수준 SELECT/INSERT/UPDATE 가 없다:

- **SELECT (anon/authenticated 동일, 29컬럼)**: id, category, title, content, user_id, authored_as, 각종 image_*, scheduled_at, display_address, display_lat, display_lng, is_location_hidden, location_radius_m, region_code, heart/comment/view_count, progress_status, visibility_status, created/updated/edited/deleted_at.
  → **`actual_lat`/`actual_lng`(정확 좌표), `photo_verification_id`, `ai_pet_species`, `is_pet_verified` 는 조회 불가.** 위치로 나가는 건 display_* 뿐이다.
- **INSERT (authenticated, 11컬럼)**: category, title, content, scheduled_at, image_*, user_id 만 — 좌표/지역/검증 필드는 직접 못 넣고 `create_post_verified` RPC + 트리거가 채운다.
- **UPDATE (authenticated, 23컬럼)**: 위 SELECT 집합에서 카운터(heart/comment/view_count)와 `authored_as`·`edited_at` 을 뺀 나머지. 진행/가시성 상태도 들어 있지만 전이 자체는 `trg_posts_validate_transition` 이 검증한다.

> **2026-08-04 회수**: UPDATE 그랜트에 `actual_lat`/`actual_lng` 가 남아 있어, 인증 사용자가
> 자기 글에 PATCH 로 **정확 좌표를 써 넣을 수** 있었다(읽지는 못하지만 DB 에는 남는다).
> 그렇게 들어온 값은 `log_location_usage` 가 AFTER **INSERT** 라 위치 이용 기록에도 안 남고,
> 어떤 뷰·RPC 로도 노출되지 않아 **아무도 모른 채 쌓인다** — "수집하지 않는다" 고 공지한 값이
> 조용히 저장될 수 있는 상태였다. 앱에 해당 컬럼 참조가 없고 실제 저장 행도 0건임을 확인한
> 뒤 `20260804140000` 으로 회수했다. 값을 채우는 `create_post_verified` 는 SECURITY DEFINER
> 라 이 그랜트가 필요 없다.

`pets`:
- **SELECT**: 전체 프로필·AI 판정 컬럼 공개(anon 포함).
- **INSERT (authenticated, 14컬럼)**: 기본 프로필 컬럼 + `primary_guardian_id` 만 — `identity_verified`, `ai_*`, `pet_match_count`, `trust_score`, `verify_post_count` 는 직접 설정 불가(트리거·RPC 가 올린다).
- **UPDATE (authenticated, 14컬럼)**: 프로필 컬럼 + `pet_status`. `primary_guardian_id` 는 INSERT 에만 있고 UPDATE 에는 **없다** — 소유권 이전은 트리거/RPC 만 할 수 있다.

기타: `dong_centroids`, `facilities`, `facility_reviews`, `pet_identity_frames`, `photo_verifications`, `public_profiles` 및 모든 뷰는 anon/authenticated 에 **SELECT 만** 부여(쓰기는 RPC/서버 전용).

> **`dong_centroids`·`phone_verifications`·`photo_verifications` 는 목록에서 빠졌다**(2026-08-05, `20260805100000`). 셋 다 **RLS 가 켜져 있고 정책이 0개**라 SELECT 그랜트가 있어도 클라이언트는 항상 0행을 받았다 — 즉 그 그랜트는 아무 일도 하지 않으면서 권한 목록만 "읽어도 되는 표" 로 보이게 했다. `phone_verifications` 는 OTP 코드를 담으므로 그 오해가 특히 비싸다. 읽기는 전부 SECURITY DEFINER RPC 가 한다.
>
> `app` 스키마 테이블 9개도 같은 상태(RLS on + 정책 0)인데 그쪽은 **의도한 그대로**다 — 스키마 USAGE 자체가 없어 클라이언트 경로가 아예 없고, service_role 만 접근한다. `post_pets` 는 2026-08-03 부터 쓰기 3종이, `pet_guardian_invites` 는 2026-08-04 부터 INSERT 가 REVOKE 됐다(0032 §3·§7.6) — 둘 다 정책은 남겨 뒀다. 지금은 도달할 수 없지만 그랜트가 되살아나는 날에도 조건은 남아 있어야 한다. 나머지 일반 테이블은 테이블 수준 풀 권한 + RLS 로 통제. (`spatial_ref_sys`, `geometry_columns` 등 PostGIS 시스템 객체는 기본 그랜트 그대로.)

### 10.3. 함수 EXECUTE 권한 (2026-08-04 실측, PostGIS 제외 109개)

| 부류 | 개수 | 뜻 |
|---|---|---|
| service_role 전용 | 29 | 서버(Edge Function)·크론만 호출 |
| authenticated 만 | 70 | 로그인 필요 |
| anon 포함 | 10 | 로그인 전에도 호출 가능 |

**service_role 전용 29개** — 토큰 발급·회전, 가입, 비밀번호, 검증 기록, 푸시 파이프라인, 업체 심사 접수, 공유 뷰어처럼 신뢰 경계 밖에 두면 안 되는 것들:
`_push_pref_allows`, `apply_business_profile`, `bump_token_version`, `business_doc_purge_done`, `business_doc_purge_take`, `change_password_and_rotate`, `dong_centroid_seeds`, `enroll_pet_identity`, `get_login_user`, `get_password_hash`, `login_issue_refresh`, `push_dispatch_batch`, `push_report`, `rate_limit_hit`, `record_auth_log`, `record_location_verification`, `record_photo_verification`, `reset_password_user`, `rls_auto_enable`, `rt_issue`, `rt_revoke_family`, `rt_revoke_user`, `rt_rotate`, `set_pet_ai_reference`, `share_view_click`, `share_view_load`, `signup_lite_user`, `signup_user`, `update_password_hash`.

**anon 포함 10개** — `check_username_available`(로그인 전 필요), `session_alive`, 시설 조회 5종(`facilities_search`, `facilities_within`, `facility_all_categories`, `facility_review_by_id`, `facility_reviews_of`, `facility_sibling_ids`), `record_client_error`(§7.12), 그리고 `block_user`.
- `block_user` 가 anon 목록에 있는 건 **그랜트가 필요 이상으로 넓은 것**이다. 함수 첫 줄이 `app.uid()` NULL 이면 42501 을 던지므로 실제 위험은 없지만, 의도한 대상은 authenticated 다.

**`admin_*` 계열은 anon 이 아니라 authenticated 전용**이고, 그 위에 함수 본문 첫 줄의 `app.is_admin()` 체크가 42501 `forbidden` 을 던진다 — 권한 판정을 그랜트가 아니라 본문에 둔 이유는 §7.9 참조.

`app` 스키마 함수들은 클라이언트 롤에 스키마 USAGE 자체가 없어 직접 호출 경로가 없다.

---

## 11. Storage

### 버킷 (2026-08-04 실측)

| id | public | file_size_limit | allowed_mime_types |
|---|---|---|---|
| `media` | **true (공개)** | 104,857,600 (100MB) | `image/jpeg`, `image/png`, `image/webp`, `image/gif`, `image/heic`, `image/heif`, `video/mp4`, `video/quicktime`, `video/webm`, `video/3gpp` |
| `business-docs` | false (비공개) | 10,485,760 (10MB) | `image/jpeg`, `image/png`, `image/webp`, `application/pdf` |

- `media` 는 **공개 버킷**이다 — 업로드된 객체는 public URL 로 누구나 읽을 수 있다(프로필/게시글/채팅 이미지, 시설 후기 사진·영상, 펫 신원 프레임 등). 경로 규약은 `<user_id>/<category>/<파일>`.
- `business-docs` 는 비공개이며 업체 증빙 서류 전용. 파기는 `app.business_doc_purge_queue` + pg_cron `business-docs-purge`(§3.8).

### storage.objects RLS 정책 7개

| 정책 | cmd | 대상 |
|---|---|---|
| `media owner insert` / `update` / `delete` | INSERT/UPDATE/DELETE | `media` 아래 **자기 폴더**(`app.uid()`) |
| `media lite review insert` | INSERT | 자기 폴더의 **`facility_review/` 한 칸만**, `app.uid_lite()` 기준(2026-08-04 신설) |
| `business docs owner insert` / `owner select` | INSERT/SELECT | `business-docs` 아래 자기 폴더 |
| `business docs admin select` | SELECT | `business-docs` 전체, `app.is_admin()` |

- `media` 의 **공개 읽기 정책은 없다.** 공개 버킷이라 읽기는 정책이 아니라 버킷 속성으로 열린다 — 초기에 있던 `media public read` 는 이후 마이그레이션이 drop 했다.
- `media lite review insert` 가 별도로 필요한 이유: 다른 정책은 전부 `app.uid()` 기준이라 **`status='lite'` 인 간이 회원은 후기 사진을 올릴 수 없었다**(0032 §1.1). 범위를 `facility_review/` 로 좁혀 열었다.

> **2026-08-04 제한 신설(0032 §7.7).** 그전에는 크기·MIME 제한이 **둘 다 없었다.**
> 공개 버킷은 저장된 content-type 을 응답 헤더로 그대로 내보내고(실측: 공개 URL 에
> `X-Content-Type-Options: nosniff` 도 `Content-Disposition` 도 없다), 쓰기 통제는
> 경로 규약뿐이라 **로그인한 누구나 자기 폴더에 `text/html` 을 올려 supabase.co
> 도메인에서 살아 있는 페이지를 만들 수 있었다.** `image/svg+xml` 은 이미지처럼 보이면서
> 스크립트를 품는다. 그래서 `image/*` 와일드카드를 쓰지 않고 목록을 명시한다 —
> 와일드카드로는 svg 를 뺄 수가 없다.
>
> 허용 목록이 이 모양인 근거: jpeg/png 는 현재 운영 객체 전부, webp/gif 는 갤러리 경로,
> **heic/heif 는 `_normalizePhoto` 가 디코드 실패 시 원본을 그대로 올리기 때문**(빼면 비-Safari
> HEIC 사용자만 조용히 깨진다), 영상 4종은 iOS(quicktime)·안드로이드 갤러리 컨테이너.
> 크기 100MB 는 앱의 동영상 상한과 같은 값이다(버킷 상한은 MIME 별로 못 나눈다).
>
> ⚠️ **남는 위험**: 공개 버킷이라 URL 을 아는 누구나 원본(사진 검증 원본·펫 신원 프레임)을
> 볼 수 있다. 또한 MIME 은 **선언값**만 검사되므로 jpeg 라고 선언하고 다른 바이트를 넣을 수는
> 있다 — 다만 그 경우에도 서빙 헤더가 `image/jpeg` 라 브라우저가 실행하지 않는다.

## 12. Realtime

`supabase_realtime` publication 에 포함된 테이블은 **2개**:

| 테이블 | 용도 |
|---|---|
| `public.chat_messages` | 채팅방 실시간 메시지 수신 (INSERT/UPDATE 구독 — soft delete 반영 포함) |
| `public.notifications` | 인앱 알림 실시간 수신 (새 알림 뱃지/토스트) |

- 두 테이블 모두 전 컬럼이 발행되며 row filter 는 없다 — 수신 범위 제한은 **RLS 로 강제**된다(chat_messages 는 방 멤버만, notifications 는 본인 것만 SELECT 가능하므로 Realtime 도 그 범위만 전달됨).
- 그 외 테이블(posts, comments 등)은 Realtime 발행 대상이 아니다 — 폴링/재조회 방식.

> ⚠️ **2026-08-04까지 `notifications` 는 마이그레이션에 없었다.** 운영에는 있었지만
> 어느 시점에 직접 추가된 것이라, **마이그레이션만으로 세운 DB(CI·재해복구·스테이징)
> 에서는 앱의 알림 구독이 오류 없이 조용히 아무 이벤트도 못 받았다** — 구독은 성공으로
> 보이는데 벨 배지·알림 목록·포그라운드 알림이 전부 죽는다. publication 은 데이터베이스
> 레벨 객체라 `pg_dump -n public -n app` 대조 밖이어서 리플레이 CI 도 못 잡았다.
> `20260804120000` 으로 남겼고, 이제 `supabase/schema/outofband.txt` 가 함께 대조된다
> (0032 §6.3).

---

### 부록: 오류 코드 관례

- `42501 (insufficient_privilege)`: 인증 실패(`not_authenticated`) 또는 관리자 아님(`forbidden`).
- `P0001 (raise_exception)`: 비즈니스 규칙 위반. 영어 스네이크 코드(`username_taken`, `phone_not_verified`, `invalid_status`, `report_not_found`, `invalid_token` …) 또는 트리거의 한국어 메시지(`'applications: 본인 게시글에는 지원할 수 없습니다'`, `'다른 사용자가 먼저 수락하였습니다'` 등). 클라이언트는 message 프리픽스로 도메인을 식별한다.

---

## 13. 마이그레이션 이력

이 저장소가 관리하는 마이그레이션 **199건**(적용 순서 = 파일명 타임스탬프). 설명은 각 파일 헤더 주석의 첫 줄이다.
`20260603*` 이전의 기반 스키마는 저장소 밖에서 적용됐고 `supabase/schema/baseline.sql` 로 역산해 두었다(README 참고).

> ⚠️ **파일명 타임스탬프 ≠ 이력 테이블의 version.** `supabase_migrations.schema_migrations`
> 에는 MCP `apply_migration` 이 적용한 **시각**이 들어가 있어 파일명과 다르다. 재현의
> 정본은 **파일명 순서**이고(리플레이 CI 가 그렇게 쌓는다), 이력 테이블은 참고용이다.
> `supabase db push` 는 쓰지 않는다(README).
>
> 파일명이 겹치는 쌍이 둘 있다 — `20260716120000`(business_hours / facility_review_comments),
> `20260718090000`(notification_polish / sibling_match_relax). 글롭 사전순이 결정적이고
> 대상 객체가 겹치지 않아 무해하지만, 버전 문자열이 유일하다는 전제는 깨져 있다.

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
| `20260702120000` | `facility_all_categories` | 같은 업체(이름+주소 동일)가 공공데이터상 카테고리별 여러 행으로 존재(예: 동물병원이면서 |
| `20260702130000` | `drop_dup_device_token_index` | device_tokens.token 에 unique 인덱스가 2개 존재(중복): 원래 UNIQUE 제약의 |
| `20260703100000` | `update_my_post_and_schedule_notify` | 내 게시글 수정(제목/내용/약속일정) + 일정 변경 시 진행 중 지원자에게 알림. |
| `20260703110000` | `post_edited_at_and_image_edit` | 게시글 수정 보강: (A) 수정됨 표기용 edited_at, (B) free/adoption 사진 편집. |
| `20260703120000` | `pet_trust_score` | 펫 신뢰도(trust_score) 시스템. |
| `20260705120000` | `revoke_anon_execute_write_admin_rpcs` | 로그인/관리자 전용 RPC 에서 anon(비로그인) 실행권한 제거. |
| `20260709100000` | `pet_guardians_public_rpc` | 펫 공개 프로필의 보호자 목록(공동보호자 포함) 조회 RPC. |
| `20260709150000` | `chat_leave_room` | 채팅방 나가기 (0033 후속): chat_room_members.left_at + 목록 제외 + 나가기 RPC. |
| `20260709160000` | `chat_block_when_left` | 나간 채팅방 잠금: 한쪽이 나간(left_at) 방에는 누구도 새 메시지를 보낼 수 없다. |
| `20260709170000` | `withdraw_and_consents` | 회원 탈퇴 + 가입 동의 기록 (법률 문서 정합 작업 후속). |
| `20260710090000` | `argon2id_password_hashing` | 비밀번호 해싱을 bcrypt(pgcrypto) → argon2id(엣지펑션 해싱)로 전환. |
| `20260710120000` | `rt_rotate_lost_rotation_recovery` | refresh 회전 유실 복구 — 세션 소실 버그 수정. |
| `20260710150000` | `chat_new_room_after_leave` | 나간 뒤 다시 대화를 시작하면 새 채팅방 생성 (0033/0034 후속). |
| `20260710180000` | `chat_rooms_profile_image` | 채팅 목록에 상대 프로필 사진 노출 — 타일 블러 배경용 (뷰 끝에 컬럼 추가). |
| `20260710200000` | `notifications_delete_policy` | 본인 알림 삭제 허용 — 확인한 알림은 목록에서 제거(읽음 아카이빙 대신 삭제 UX). |
| `20260711120000` | `admin_ops_metrics` | 관리자 운영 지표·비용 RPC (AI 사진인증 / Solapi 문자 / 일일 활성 사용자). |
| `20260711130000` | `retention_purge_batch` | 위치정보/인증코드/접속기록 보존기간 경과분 자동 파기 |
| `20260711140000` | `auth_logs` | 로그인 접속 로그 (개인정보 처리방침 §3: 접속 로그·IP 3개월 보존). IP 는 SHA-256 해시로만 저장. |
| `20260711150000` | `post_delete_scrub_coords` | 게시글 삭제 시 실좌표 즉시 파기("지체 없이" — 사업계획서 §3.4 / 위치기반서비스 이용약관 제8조④). |
| `20260712033510` | `location_usage_logs` | 위치정보 이용·제공사실 확인자료 자동 기록·파기 (위치정보법 제16조 제2항, |
| `20260712041855` | `withdraw_purge_location_history` | 탈퇴(=위치정보 이용 동의 철회) 시 본인 위치 이력 즉시 파기. |
| `20260712045112` | `admin_broadcast_system_notice` | 전체 공지 발송 RPC (약관·처리방침 개정 고지 등). |
| `20260713112529` | `photo_verifications_purpose_pet_identity` | 반려동물 신원 인증(enroll-pet-identity) 실패도 photo_verifications 에 기록하기 위해 |
| `20260713112812` | `photo_verifications_purpose_widen` | purpose varchar(10) → varchar(20): 'pet_identity'(12자) 수용. |
| `20260713200335` | `create_post_region_gate` | create_post_verified v3 — 동네(지역) 인증 게이트 추가. |
| `20260713201500` | `create_post_region_gate_overload12` | create_post_verified 12-파라미터 오버로드에도 동네 인증 게이트 적용. |
| `20260713202000` | `drop_create_post_verified_9param` | create_post_verified 9-파라미터(구버전) 오버로드 제거 — 단일화. |
| `20260713202500` | `posts_region_gate_trigger` | posts INSERT 최종 방어선 — 동네 인증 게이트를 트리거로. |
| `20260713210000` | `leave_room_block_support` | 고객센터(admin_inquiry) 방은 나갈 수 없게 — leave_chat_room 게이트. |
| `20260714000000` | `block_self_guardian_invite` | 자기 자신 공동보호자 초대 차단 (DB 백스톱). |
| `20260714120000` | `business_account_core` | 업체(사업자) 계정 — 코어 스키마 (0025 §2·§3.3·§4). |
| `20260714121000` | `business_apply_rpcs` | 업체 등록 신청 RPC + 계정 전환 RPC (0025 §4~§5). |
| `20260714122000` | `business_admin_rpcs_withdraw` | 업체 승인 관리자 RPC + 규칙 튜닝 RPC + 탈퇴 연동 (0025 §6·§2.2·§3.3). |
| `20260715090000` | `business_rows_retention_purge` | 업체 인증 '행 데이터' 보존기간 파기 (0025 §3.3 · 처리방침 §3 정합). |
| `20260715100000` | `business_docs_purge_cron` | 업체 서류 파기 크론 연결 (0025 §3.3 · 운영점검주기 v1.2 의 "크론 연결 대기" 해소). |
| `20260715120000` | `posts_authored_as` | 게시글 작성 모드 구분 (업체 프로필 분리 — "같은 계정, 분리된 프로필"). |
| `20260715130000` | `business_info_edit_sync` | 승인 업체 정보 수정 + 지도(facilities) 동기화 (0025 후속 — 업체 프로필 분리 2차). |
| `20260715140000` | `business_photo_map_hero` | 업체 대표 사진 → 지도 상세 히어로 (0025 후속 — 업체 프로필 분리 3차). |
| `20260715160000` | `business_chat_context_public_fields` | 업체 채팅 분리(컨텍스트 축) + 공개 프로필 업체 필드 (0025 후속 — 프로필 분리 4차). |
| `20260715170000` | `business_identity_privacy` | 개인↔업체 정체성 연결 차단 (0025 후속 — "어떤 사용자가 어떤 업체를 운영하는지 |
| `20260715180000` | `comments_authored_as` | 댓글 작성 모드 분리 (0026 §5-1 해소) — 업체 모드로 단 댓글은 상호로 표시. |
| `20260715190000` | `applications_block_business_mode` | 업체 모드의 매칭 흐름 차단 (0026 §5-2 해소). |
| `20260715200000` | `business_face_always_public` | 업체 얼굴 상시 공개 (0026 §2 개정) — "일반 모드 = 업체 오프라인" 결합 해제. |
| `20260715210000` | `business_photo_face` | 업체 얼굴의 프로필 사진 = 대표 사진 (0026 §2 보강). |
| `20260715220000` | `facilities_owner_link` | 지도 시설 → 인증 업주 링크 (지도 상세 히어로 탭 → 업체 프로필 이동용). |
| `20260715230000` | `facility_reviews_multiple` | 시설 후기 복수 작성 허용 + 방문 차수(visit_no) 표시. |
| `20260716000000` | `posts_news_category` | 업체 소식(news) 카테고리 (0025 후속). |
| `20260716010000` | `business_news_region_exempt` | 업체 소식(news)은 동네 인증 없이 작성 가능 — 지역은 사업장 주소 기준. |
| `20260716090000` | `facilities_owner_definer` | 지도 시설 RPC 의 owner_user_id 가 앱에서 항상 NULL 이던 버그 수정. |
| `20260716120000` | `business_hours` | 업체 영업시간 (자유 서식 한 줄, 예: "매일 10:00 - 20:00 (월 휴무)") |
| `20260716120000` | `facility_review_comments` | 시설 방문 후기 댓글 — 게시글 댓글(comments) 문법 미러링. |
| `20260716130000` | `facility_review_by_id` | 후기 단건 조회 RPC — 후기 댓글 알림(review_comment) 딥링크용. |
| `20260716150000` | `block_own_facility_review` | 자기 업체 후기 금지 (0025/0026 후속) |
| `20260717000000` | `pawing_context_and_news_region_fallback` | 업체 소식 피드 미노출 + 업체 팔로우 목록 미표시 수정 (0025 후속). |
| `20260717010000` | `pawing_dual_face` | 두 얼굴(개인/업체) 독립 팔로우 (0025 후속). |
| `20260717090000` | `facilities_owner_verified_at` | 지도 시설 RPC 에 업주 인증(승인) 시각 노출 — 인증 마커끼리 충돌 시 |
| `20260717120000` | `multi_category_unify` | 다중 카테고리 업체 통합 (병원+미용 병행 등 — 같은 업체가 카테고리별 별도 행) |
| `20260717121000` | `facilities_lateral_after_limit` | 20260717120000 후속 성능 보정 — 업주/평점 lateral 을 LIMIT 이후에. |
| `20260717150000` | `engagement_notifications` | 참여 알림 3종: 게시글 하트(post_heart) · 포잉(pawing_follow) · |
| `20260718000000` | `review_notification_wording` | 사용자 평가 → '후기' 용어 통일(앱 UI 변경과 동기화): 알림 문구 변경. |
| `20260718010000` | `pawmate_face_separation` | Pawmate(나를 팔로우) 얼굴 분리 (0025 후속). |
| `20260718065841` | `security_advisor_hardening` | Security advisor 급증 대응 (2026-07-18, advisor 99건 → 76건) |
| `20260718071543` | `dong_centroid_seeds_service_only` | RPC 게이트 전수 감사(2026-07-18) 후속: dong_centroid_seeds 는 sync-dong-centroids |
| `20260718090000` | `notification_polish` | 알림 문구 다듬기 + 업체 방문 후기 알림 신설 |
| `20260718090000` | `sibling_match_relax` | 같은 업체(형제 행) 판정 보강 — 주소 정확 일치의 실데이터 함정 수정 |
| `20260718091000` | `facilities_single_sibling_scan` | 20260718090000 후속 성능 보정 — 형제 스캔을 행당 한 번으로. |
| `20260718120000` | `review_owner_switch_hint` | 후기 상세 딥링크 진입 시 '업체 모드로 전환할까요?' 제안 판정 |
| `20260718150000` | `mode_action_guards` | 계정 모드별 행동 격리 (양방향) |
| `20260718160000` | `pawing_new_post_face_filter` | pawing_new_post 얼굴 필터 복원. |
| `20260718170000` | `delete_my_chat_message` | 채팅 메시지 삭제(본인 것만) — SECURITY DEFINER RPC. |
| `20260718180000` | `chat_retention_admin_history` | 채팅 삭제 30일 유예 하드삭제 + 관리자 대화 내역 조회. |
| `20260718190000` | `retention_restore_lost_purges` | cleanup_retention 유실 항목 복원. |
| `20260719090000` | `sibling_match_name_contains` | 같은 업체(형제 행) 판정 3차 보강 — 이름이 다른 다중 카테고리 업체(댕댕즈 사례) |
| `20260719091000` | `sibling_match_inline_perf` | 20260719090000 성능 보정 — 형제 판정의 st_dwithin 을 인라인해 gist 인덱스 사용. |
| `20260719120000` | `search_dedupe_siblings` | 시설 검색 결과에서 같은 업장(형제 행) 중복 제거 |
| `20260719150000` | `search_sibling_categories` | 검색 dedupe 대표 행에 형제 전체 카테고리 배열(categories) 노출 |
| `20260719180000` | `public_profiles_counts` | public_profiles 뷰에 개인 얼굴 통계(받은 후기·Pawing·Pawmate) 추가 |
| `20260719210000` | `public_user_pets` | 타 사용자 프로필의 반려동물 목록 — 공동보호(co_guardian) 펫 포함 |
| `20260719230000` | `notify_pet_in_post` | 게시글에 공동보호 펫 등록 시 다른 보호자에게 알림 |
| `20260720090000` | `pawing_suppress_pet_in_post` | pawing_new_post 억제 — 같은 게시글에 pet_in_post 가 이미 갔으면 중복 방지 |
| `20260720100000` | `post_photo_any_pet_target` | 게시글 사진 인증: 촬영 대상을 '연결한 펫 중 아무나'로 완화. |
| `20260722120000` | `check_nickname_available` | 닉네임 중복확인 RPC — 내정보 수정 실시간 선체크용. |
| `20260722160000` | `share_viewer_p0` | 0028 P0 — 공유 뷰어 기반: share_links · funnel_events · 발급/회수 RPC |
| `20260722180000` | `posts_block_trader` | 0028 §2 — 영업자 공통 차단선: 승인 업체 계정의 분양·입양 게시 금지 |
| `20260722200000` | `review_incentive_disclosure` | 0028 §6 — 대가성 후기 표시 (표시광고법 경제적 이해관계 표시 의무) |
| `20260722220000` | `business_licenses` | 0028 §1 — 업종 모듈 권한: business_licenses (계정당 업종별 증빙 1행) |
| `20260722230000` | `funnel_retention_cron` | 퍼널 원시 이벤트 보존 1년 크론 (0028 §7 — "원시 이벤트 1년, 경과분 배치 삭제"). |
| `20260722235000` | `share_view_hero` | share_view_load 에 인증 업체 대표 사진·영업시간 추가 (0028 §3 콜드스타트 완화) |
| `20260723000000` | `share_view_review_photos` | share_view_load 후기에 사진 썸네일 추가 (0028 §3) |
| `20260723001000` | `share_view_photo_first` | 공유 뷰어 후기 정렬: 사진 후기 우선 → 최신순 (0028 §3) |
| `20260723002000` | `share_view_owner_verified` | share_view_load 에 owner_verified 플래그 추가 (0028 §3) |
| `20260723010000` | `care_reports_p1` | 0028 P1 — 케어 리포트(미용 전후 사진) 서버: care_reports · 발행/목록/claim RPC |
| `20260723030000` | `license_apply_with_registration` | 업종 인증을 업체 등록과 한 번에 신청 (0028 §1 보완) |
| `20260724100000` | `boarding_journal_p2` | 0028 P2 — 위탁 알림장 서버: care_threads · 반복 발행 · 스레드 claim |
| `20260724150000` | `starter_p3` | 0028 P3 — 분양 스타터: 스타터 QR 랜딩 · 접종 일정 알림 |
| `20260724180000` | `media_video` | 영상 첨부 — 게시글(자유·소식) · 시설 후기 · 채팅 |
| `20260725100000` | `post_share` | 게시글 공유 — 모든 카테고리 게시글을 공유 뷰어 링크로 (0028 §3 인프라 재사용) |
| `20260726120000` | `share_view_post_id` | 공유 뷰어 → 웹앱 연결: post 분기에 게시글 id 노출 |
| `20260727100000` | `lite_reviewer` | 간이 회원(lite) — 후기 작성 전용 비회원 계정 (0029 P0) |
| `20260727170000` | `guest_facility_read` | 시설 조회 RPC 를 비로그인에 개방 (0029 후속) |
| `20260728103000` | `photo_gate_post_milestones` | 게시글 사진 인증 게이트 — '신뢰도 3 이상 면제'에서 '펫별 1·4·10번째 글'로 변경. |
| `20260728180000` | `device_tokens_web_platform` | 웹 푸시(Phase D) — device_tokens.platform 에 'web' 허용 |
| `20260729070000` | `capture_prod_drift` | 운영 DB 드리프트 포착 — 마이그레이션 없이 직접 적용됐던 정의를 저장소로 되돌린다. |
| `20260730090000` | `lock_post_after_appointment` | 약속이 완료된 게시글은 수정할 수 없다 |
| `20260731080000` | `client_error_collection` | 클라이언트 오류 수집 — 외부 리포팅 서비스 대신 우리 DB 로 (0031) |
| `20260801090000` | `client_error_ratelimit_per_ip` | record_client_error 보완 두 가지. |
| `20260801100000` | `block_user` | 사용자 차단 — 실행 RPC + 피드 필터링 (App Store 1.2 대응) |
| `20260801130000` | `block_chat_and_comments` | 차단 효력 확대 — 채팅(전송·목록)과 댓글 (App Store 1.2) |
| `20260801140000` | `ratelimit_trusted_client_ip` | 익명 레이트리밋의 IP 출처를 x-forwarded-for → cf-connecting-ip 로 바꾼다. |
| `20260803090000` | `token_release_and_reconcile_rpc` | 클라이언트가 부를 수 있어야 하는 두 가지를 public 으로 노출한다. |
| `20260803180000` | `lite_token_scope` | 간이 후기 토큰의 권한 범위를 실제로 '후기만' 으로 좁힌다. |
| `20260803181000` | `reset_password_consume_verification` | 비밀번호 재설정 인증을 **소진**시킨다 — 30분 재사용 창을 닫는다. |
| `20260803182000` | `post_pets_revoke_direct_writes` | post_pets 직접 쓰기 권한 회수 — 사진 인증 게이트(1·4·10번째)의 우회로를 막는다. |
| `20260803190000` | `block_severs_contact` | 차단이 실제로 연결을 끊게 한다 — 표시만 가리던 것을 접촉 자체 차단으로. |
| `20260804090000` | `lite_account_phone_purge` | 간이 후기 계정의 전화번호 파기 — 이미 이용자에게 한 약속을 실제로 이행한다. |
| `20260804120000` | `realtime_publication_notifications` | notifications 를 supabase_realtime publication 에 넣는다 — **운영에는 이미 있다.** |
| `20260804140000` | `posts_revoke_actual_coords_update` | posts.actual_lat/lng 의 클라이언트 UPDATE 권한 회수 — 안 받겠다고 한 값이 조용히 저장될 수 있었다. |
| `20260804160000` | `ops_alarms` | 운영 알람 — 모으기만 하고 알려 주지 않던 것을 알리게 한다. |
| `20260804180000` | `pgi_revoke_direct_insert` | 공동보호자 초대 직접 INSERT 회수 — 엣지 함수의 열거 방지 리밋을 우회할 수 있었다. |
| `20260804200000` | `media_bucket_limits` | media 버킷 MIME·용량 제한 — 공개 CDN 이 임의 파일 호스팅이 되지 않게. |
| `20260804220000` | `rls_initplan` | RLS 의 무인자 헬퍼를 `(select …)` 로 감싸 행마다 부르던 것을 한 번만. |
| `20260804230000` | `fk_indexes` | 조회 경로가 있는 FK 7건에 인덱스. |
| `20260805090000` | `block_hides_reads` | 차단이 읽기도 막게 — 화면만 가려져 있고 데이터는 열려 있었다. |
| `20260805100000` | `revoke_dead_selects` | 효과 없는 SELECT 그랜트 3건 회수 — 권한 목록이 '읽어도 되는 표' 로 보이게 했다. |
