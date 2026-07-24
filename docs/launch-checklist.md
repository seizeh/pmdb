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
