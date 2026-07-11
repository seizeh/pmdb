-- 위치정보/인증코드 보존기간 경과분 자동 파기 (사업계획서 §3.4 / 개인정보 처리방침 이행).
-- 기존 cleanup_auth()(refresh_tokens·rate_limits) 는 위치정보 파기를 다루지 않아,
-- 문서가 약속한 6개월 파기가 자동화되지 않던 공백을 메운다. pg_cron 매일 실행.
create or replace function app.cleanup_retention()
returns void
language sql
security definer
set search_path to ''
as $function$
  -- 전화 인증코드(OTP): 발급 1일 경과분 파기 (코드 TTL 5분, 데이터 최소화)
  delete from public.phone_verifications where created_at < now() - interval '1 day';
  -- 위치 인증 이력: 6개월 경과분 파기
  delete from public.location_verifications where created_at < now() - interval '6 months';
  -- 사진 인증 로그(촬영 좌표 포함): 6개월 경과분 파기 (스토리지 이미지는 게시글 수명과 함께 관리)
  delete from public.photo_verifications where created_at < now() - interval '6 months';
$function$;

-- 매일 03:23 실행 (cron 은 UTC 기준이나 일 1회라 시각 민감도 낮음). 동명 잡은 갱신됨.
select cron.schedule('retention-purge', '23 3 * * *', $$select app.cleanup_retention();$$);
