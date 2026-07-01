-- 레이트리밋 리뷰 반영(A): app.rate_limits 무한 증가 방지.
--   rate_limit_hit 이 분 단위 버킷을 계속 INSERT 하는데 삭제 주체가 없었다(pg_cron 은 규모 시).
--   호출의 ~2% 에서 만료 버킷을 기회적으로 삭제(expires_at 인덱스 range scan → 저비용).
--   대량 정리는 여전히 §8 pg_cron 권장(이 함수는 백스톱).
create or replace function public.rate_limit_hit(p_key text, p_max integer, p_window_seconds integer)
returns boolean language plpgsql security definer set search_path to '' as $function$
declare
  v_win bigint := floor(extract(epoch from now()) / greatest(p_window_seconds, 1));
  v_bucket text := p_key || ':' || v_win;
  v_count integer;
begin
  if random() < 0.02 then
    delete from app.rate_limits where expires_at < now();
  end if;
  insert into app.rate_limits(bucket, count, expires_at)
  values (v_bucket, 1, now() + make_interval(secs => p_window_seconds))
  on conflict (bucket) do update set count = app.rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_max;
end $function$;
