-- RPC 게이트 전수 감사(2026-07-18) 후속: dong_centroid_seeds 는 sync-dong-centroids
-- Edge Function 이 service_role 클라이언트로만 호출한다(앱 직접 호출 없음).
-- 지역별 사용자 위치 평균(민감 좌표 파생값)을 반환하므로 클라이언트 롤 실행권한 회수.
revoke execute on function public.dong_centroid_seeds() from authenticated;
