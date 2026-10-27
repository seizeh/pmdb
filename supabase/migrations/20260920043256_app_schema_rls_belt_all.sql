-- app 스키마 RLS 벨트를 전 테이블로 통일 — 나머지 10개 (0032 '부분 적용' 유형 해소)
--
-- app 은 PostgREST 미노출 + 테이블 그랜트 0 이라 지금도 클라이언트가 도달하지 못한다.
-- 그러나 민감 테이블 9개(refresh_tokens 등)에만 "정책 없는 RLS = 실수 그랜트 보험"을
-- 감아 두고, 이후 생긴 테이블(0028 계열·운영 설정류)은 빠져 있었다 — 같은 판단을
-- 절반에만 적용한 상태. care_reports/care_threads 는 전화번호 HMAC 을 담아 민감도
-- 기준으로도 벨트 대상이다.
--
-- 정상 경로 무영향 근거: 쓰기 주체는 SECURITY DEFINER 함수(소유자=postgres=테이블
-- 소유자, FORCE 아님 → RLS 비적용) · service_role(BYPASSRLS) · pg_cron(postgres) 뿐.
-- 같은 상태(RLS on·정책 0)인 rate_limits·withdrawn_users·care_config 를 크론과
-- definer 가 매일 쓰고 있다. INVOKER 함수의 app 테이블 참조는 phone_hmac→care_config
-- 1건인데 care_config 는 이미 RLS on 으로 작동 중.

alter table app.business_licenses     enable row level security;
alter table app.care_reports          enable row level security;
alter table app.care_threads          enable row level security;
alter table app.funnel_events         enable row level security;
alter table app.ops_alarm_config      enable row level security;
alter table app.ops_alarms            enable row level security;
alter table app.push_config           enable row level security;
alter table app.rate_limit_trips      enable row level security;
alter table app.share_links           enable row level security;
alter table app.vaccination_events    enable row level security;
