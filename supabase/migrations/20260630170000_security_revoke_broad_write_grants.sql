-- 보안 방어심화(MEDIUM): anon/authenticated 의 불필요한 직접 쓰기 GRANT 회수. 운영 적용 완료(형상 기록).
--
-- 배경: 아래 테이블들은 RLS on + 쓰기 정책 0개라 이미 직접 쓰기가 막혀 있고(앱은
--   RPC/Edge Function = service_role 로만 기록), 그럼에도 anon/authenticated 에 광범위
--   DML GRANT 가 남아 있었다. permissive 쓰기 정책 1개 추가 또는 RLS 비활성 시 즉시
--   노출되는 잠재 경로라, 최소권한 원칙으로 쓰기 GRANT 를 회수한다. 읽기(SELECT)는 유지.
--   (CRITICAL 뷰 쓰기 GRANT 건 20260630160000 의 후속 정리.)

revoke insert, update, delete, truncate, references, trigger on
  public.facilities,
  public.dong_centroids,
  public.photo_verifications,
  public.pet_identity_frames,
  public.facility_reviews
from anon, authenticated;
