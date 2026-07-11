-- 위치정보/인증코드/접속기록 보존기간 경과분 자동 파기
-- (사업계획서 §3.4 / 개인정보 처리방침 §3 / 위치기반서비스 이용약관 제8조 이행).
-- 기존 cleanup_auth()(refresh_tokens·rate_limits) 는 위치정보 파기를 다루지 않아,
-- 문서가 약속한 6개월/3개월 파기가 자동화되지 않던 공백을 메운다. pg_cron 매일 실행.
--
-- 주의(FK): photo_verifications.id 는 pets.ai_ref_verification_id / posts.photo_verification_id
-- 에서 NO ACTION 으로 참조된다. 참조 중인 행을 DELETE 하면 FK 위반으로 함수 전체(단일
-- 트랜잭션)가 롤백되어 파기 잡이 매일 조용히 실패한다. 따라서 미참조 행만 삭제하고,
-- 참조 중인 행은 위치정보법상 파기 대상인 촬영 좌표(shot_*)만 스크럽한다(AI 결과는 유지).
--
-- 주의(트리거): posts 의 좌표만 바꾸는 UPDATE 는 안전하다 — check_write/set_region 은
-- BEFORE INSERT 전용이라 발사되지 않고, validate_transition 은 visibility_status 미변경 시
-- 통과하며, audit 은 is_admin + status 변경 조건이라 크론 컨텍스트에서 미발사.
create or replace function app.cleanup_retention()
returns void
language sql
security definer
set search_path to ''
as $function$
  -- 전화 인증코드(OTP): 발급 1일 경과분 파기 (코드 TTL 5분, 데이터 최소화)
  delete from public.phone_verifications where created_at < now() - interval '1 day';

  -- 위치 인증 이력: 6개월 경과분 파기 (들어오는 FK 없음, 지역인증 상태는 users 에 있어 안전)
  delete from public.location_verifications where created_at < now() - interval '6 months';

  -- 사진 인증: 6개월 경과분 중 '미참조' 행만 삭제 (pets/posts FK 위반 방지)
  delete from public.photo_verifications pv
   where pv.created_at < now() - interval '6 months'
     and not exists (select 1 from public.pets  p  where p.ai_ref_verification_id = pv.id)
     and not exists (select 1 from public.posts po where po.photo_verification_id = pv.id);

  -- 참조 중인 사진 인증 행: 촬영 좌표만 파기(스크럽) — 펫·게시글이 계속 참조하는 AI 결과는 보존
  update public.photo_verifications
     set shot_lat = null, shot_lng = null, shot_accuracy_m = null
   where created_at < now() - interval '6 months'
     and (shot_lat is not null or shot_lng is not null or shot_accuracy_m is not null);

  -- 삭제된 게시글 + 탈퇴자(users.status='deleted') 게시글의 실좌표 파기
  -- (소프트 삭제라 delete_my_post/admin 삭제 후에도 actual_lat/lng 가 잔존하던 문제 해소).
  update public.posts p
     set actual_lat = null, actual_lng = null
   where (p.visibility_status like 'deleted_%'
          or exists (select 1 from public.users u where u.id = p.user_id and u.status = 'deleted'))
     and (p.actual_lat is not null or p.actual_lng is not null);

  -- 접속 기록(post_views: ip_hash 포함) 3개월 경과분 파기 (처리방침 §3).
  -- 조회수는 posts.view_count 에 비정규화돼 있고 중복방지 버킷은 최근 것만 필요 → 기능 무영향.
  delete from public.post_views where viewed_at < now() - interval '3 months';
$function$;

-- 크론/소유자만 실행 (기존 cleanup_auth 컨벤션과 동일). SECURITY DEFINER 이므로 소유자 권한으로 동작.
revoke all on function app.cleanup_retention() from public, anon, authenticated;

-- 매일 03:23 실행 (cron 은 UTC 기준이나 일 1회라 시각 민감도 낮음). 동명 잡은 갱신됨(pg_cron 1.6+).
select cron.schedule('retention-purge', '23 3 * * *', $$select app.cleanup_retention();$$);
