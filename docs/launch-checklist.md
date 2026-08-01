# 출시 준비 체크리스트 (0028 — 스토어 URL · 유니버설 링크 · 루트 리다이렉트)

> 스토어 심사 통과로 실제 스토어 URL 이 나오는 시점에 실행하는 것들.
> 사전 준비(코드·인프라)는 전부 완료 상태이며, 각 항목은 값 채우기 수준이다.

## 1. 스토어 URL 시크릿 (share-view CTA 실동작 전환)

`share-view` 는 `?go=store` 에서 `STORE_URL_IOS`/`STORE_URL_ANDROID` 시크릿이
비어 있으면 "앱 출시 준비 중" 안내를 보여준다(index.ts). 시크릿을 채우는 즉시
모든 공유 링크·QR 의 설치 버튼이 스토어 302 로 전환된다 — 재배포 불필요.

- [ ] App Store 등록 완료 → URL 확보 (`https://apps.apple.com/kr/app/…`)
- [ ] Play 스토어 등록 완료 → URL 확보 (`https://play.google.com/store/apps/details?id=com.seizeh.pawmate`)
- [ ] Supabase 시크릿 설정:
  ```
  supabase secrets set STORE_URL_IOS=… STORE_URL_ANDROID=… --project-ref vyatppuxmpulqtxevfpk
  ```
  (대시보드 Edge Functions → Secrets 로도 가능. 설정 후 `?go=store` 스모크 테스트.)

## 2. pawmate.kr 루트 — 임시 랜딩 → 스토어 리다이렉트

`workers/share-proxy/src/index.js` 의 `LANDING` 이 임시 안내를 서빙 중.

- [ ] 루트 처리 교체: UA 분기로 iOS→App Store / Android→Play / 데스크톱→간단 소개
      (share-view 의 UA 정규식 `iphone|ipad|ipod|macintosh` 재사용).
- [ ] `workers/share-proxy` 에서 `npx wrangler deploy`.

## 3. 유니버설 링크 (iOS) — 설치자가 공유 링크를 앱으로 열기

서버 쪽은 **완료**: Worker 가 `go.pawmate.kr/.well-known/apple-app-site-association`
을 서빙 중(appID `5GVP46ZJ2H.com.seizeh.pawmate`, path `/s`). 남은 것은 앱 쪽:

- [ ] Xcode → Runner 타깃 → Signing & Capabilities → **Associated Domains** 추가:
      `applinks:go.pawmate.kr` (Runner.entitlements 에
      `com.apple.developer.associated-domains` 로 기록됨. 유료 팀 5GVP46ZJ2H 이므로
      capability 활성화 가능)
- [ ] 앱 링크 수신 배선: `app_links` 패키지를 직접 의존성으로 승격 →
      수신한 `/s?t=…` 를 라우팅. v1 라우팅 제안: 로그인 상태면
      `claim_care_reports()` 호출 후 받은 케어 기록 화면(연결된 기록이 도착해 있는
      흐름), 비로그인이면 웰컴 화면. 토큰별 정밀 라우팅(kind 해석 RPC)은 후속.
- [ ] 실기기 검증: 링크를 메모장에 붙여 길게 눌러 "PawMate 로 열기" 확인.

## 4. 앱 링크 (Android)

- [ ] 릴리스 서명키 확정 후 SHA-256 지문 추출:
      `keytool -list -printcert -keystore <release.jks>` (Play App Signing 사용 시
      Play Console → 앱 무결성에서 지문 확인)
- [ ] `workers/share-proxy/src/index.js` 의 `ANDROID_CERT_SHA256` 에 지문 추가 →
      deploy (빈 배열이면 `/.well-known/assetlinks.json` 은 404 로 안전하게 꺼져 있음)
- [ ] `AndroidManifest.xml` MainActivity 에 `autoVerify` intent-filter 추가:
      `https` + `go.pawmate.kr` + pathPrefix `/s`
- [ ] `adb shell pm get-app-links com.seizeh.pawmate` 로 verified 확인.

## 5. 출시 시점 운영

- [ ] 위치기반서비스사업 신고 수리 확인(캠페인 전제 — 0028 원칙 7)
- [ ] pmlegal 문서의 앱 내 링크·시행일 최종 확인
- [ ] 파일럿 QR 인쇄물은 그대로 유효(주소가 `go.pawmate.kr` 라 백엔드 교체 무관)
- [ ] iOS `aps-environment` 가 릴리스 빌드에서 production 인지 확인(푸시)

## 6. 베타 트랙 정의 — 업체 파일럿과 개인 사용자 베타는 별개

측정하려는 값이 서로 다른 두 트랙이며, **업체 파일럿만 돌리면 신원 인증 계열
표본은 하나도 안 모인다**(사장님은 펫 등록도, 사진 게이트 게시글 작성도 안 함).

| 트랙 | 대상 | 검증 대상 | 문서 |
|---|---|---|---|
| 업체 파일럿 (P1) | 미용업체 5~10곳 | 케어 리포트 발행·열람 흐름 | pilot-onboarding-checklist.md |
| 개인 사용자 베타 | 클로즈드(섭외 업체 지인·신원 확인된 테스터) | 펫 신원 등록(frames_from_video 섀도), 게시글 사진 인증(0.63), video_too_large 발생률 | 본 문서 §8 |

수용 리스크(결정, 사고 아님): 클로즈드 베타 동안 frames_from_video 는 섀도
모드라 프레임 바꿔치기 구멍이 열린 채 돌아간다 — 테스터가 신원 확인된
범위라 노출 대비 측정 가치가 크다고 판단(pmdb #135 에 기록). **오픈 베타로
넓히기 전에 enforce 전환 여부를 재검토할 것.**

## 7. 베타 진입 조건 (클로즈드 베타 시작 전) — **닫힌 목록**

§8 이 "언제 끝나나" 를 정의하듯, 이 절은 **"언제 시작하나"** 를 정의한다.

이 목록을 닫아 두는 이유는 하나다. 진입 조건이 열려 있으면 **"이것 하나만 더"** 가
끝나지 않는다. 코드베이스가 5만 줄이라 고칠 것은 언제나 남아 있고, 그 하루는
베타 데이터 하루와 맞바꾸는 것이다. 지금은 후자가 훨씬 비싸다.

**여기 없는 항목은 베타 진입을 막지 않는다.** 항목을 추가하려면 아래 셋 중
하나를 만족한다는 근거를 함께 적는다.

1. **없으면 데이터가 안 모이거나 못 믿는다** — 베타의 목적 자체가 사라진다
2. **없으면 배포가 안 된다** — 심사·법정 요건
3. **없으면 이용자에게 실질 피해가 난다** — 안전

### 조건

| # | 조건 | 근거 | 상태 |
|---|---|---|---|
| E1 | 클라이언트 오류 수집이 켜져 있다 | ①. 실패가 안 보이면 목적의 절반이 사라진다 | ✅ `app.client_errors` + 관리자 화면 ([ADR-0011](https://github.com/seizeh/pmdart/blob/main/docs/adr/0011-self-hosted-error-collection.md)) |
| E2 | Edge Function 실패가 관리자에게 알려진다 | ① | ✅ `alertAdmins` — `verify_ai_unavailable`, `enroll_video_too_large` |
| E3 | §8 을 판정할 계측이 돌고 있다 | ①. 종료 조건을 못 재면 베타를 끝낼 수 없다 | ✅ `photo_verifications`(`fail_reason`·`identity_score`·`frames_from_video`) |
| E4 | App Store 1.2(UGC) — 신고 · **차단** · 계정 삭제 | ②③ | 신고 ✅ / 계정 삭제 ✅ / **차단 진행 중** (pmdart #225, pmdb #144) |
| E5 | 약관 · 개인정보처리방침 게시 | ② | ✅ `pmlegal` |
| E6 | 사업자등록 · 위치기반서비스사업 신고 수리 | ② | ✅ 수리 완료 |
| E7 | TestFlight 외부 테스터 배포 승인(Beta App Review) | ② | ⏳ E4 완료가 선행 |

**남은 것은 E4 의 차단 기능 하나뿐이고, E7 은 그 결과다.**

### 진입 조건이 **아닌** 것 (명시)

아래는 전부 추적 중이지만 베타를 막지 않는다. 위 세 기준 중 어느 것도
만족하지 않기 때문이다 — 코드 품질·유지보수성 항목이지 데이터 수집이나
배포 가능성이나 이용자 안전에 걸리지 않는다.

| 항목 | 왜 진입 조건이 아닌가 |
|---|---|
| pmdart #155 God Widget 분해 | 내부 구조. 사용자에게 보이지 않고 데이터에도 영향 없다 |
| pmdart #156 상태관리·DI | 같음. #158 의 선행 조건이지 베타의 선행 조건이 아니다 |
| pmdart #158 커버리지 30% | 래칫이 하락을 막고 있다. 목표 도달은 베타와 무관 |
| pmdart #159 i18n | 클로즈드 베타 대상이 국내 사용자다 |
| pmdart #160 post_create 임시 조치 해제 | 포맷 게이트 예외 하나. 기능 영향 없음 |
| pmdart #30 동네 게시글 시트 개선 | 게시글 폭주 대비. 베타 규모(5~10명)에서 안 일어난다 |
| pmdart #157 `catch (_)` 전수 분류 | 수집은 이미 켜졌다(E1). 남은 110곳은 래칫으로 줄인다 |
| pmdb #135 frames_from_video enforce | **종료** 조건이다(§8). 판단 근거가 베타에서 나온다 |
| pmdb #136 video_too_large 근본 대응 | 같음. 발생률을 재고 나서 고른다 |

### 수용하고 시작하는 리스크 (사고 아님, 결정)

- **frames_from_video 섀도 모드** — 프레임 바꿔치기 구멍이 열린 채 돈다.
  테스터가 신원 확인된 범위라 노출 대비 측정 가치가 크다고 판단(pmdb #135).
  **오픈 베타로 넓히기 전 재검토 필수.**
- **오류 그룹핑 없음** — 같은 오류가 1,000행이 된다. 베타 규모에서 값이 작다
  ([ADR-0011](https://github.com/seizeh/pmdart/blob/main/docs/adr/0011-self-hosted-error-collection.md)).

## 8. 베타 종료 조건 (정식 출시 전 확인)

실행 항목(§1~5)과 별개로, 아래가 확인돼야 정식 출시로 넘어간다.

- [ ] frames_from_video 표본 **30건** 도달 → 오탐률 확인 → enforce 전환 판단 (pmdb #135)
- [ ] `IDENTITY_PASS_THRESHOLD 0.63` 근거 확보 — post 인증 로그의 identity_score 분포로 통과선 재검토
- [ ] `video_too_large` 발생률·기기 분포 확인 → 클라 압축 / Files API 판단 (pmdb #136)
