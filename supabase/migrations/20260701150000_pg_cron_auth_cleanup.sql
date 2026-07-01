-- pg_cron 정리잡: app.refresh_tokens(만료·오래된 회수) + app.rate_limits(만료) 주기 삭제.
-- refresh_tokens 는 grace 재발급/미로그아웃으로, rate_limits 는 분단위 버킷으로 단조증가하므로
-- (설계 §8) 백스톱으로 매시 정리한다. rate_limit_hit 의 기회적 정리와 이중.
create extension if not exists pg_cron;

create or replace function app.cleanup_auth()
returns void
language sql
security definer
set search_path to ''
as $$
  delete from app.refresh_tokens
   where absolute_expires_at < now()                                  -- family 완전 만료
      or (revoked_at is not null and revoked_at < now() - interval '1 day')  -- 오래된 회수(감사 여유 1일)
      or (revoked_at is null and expires_at < now() - interval '1 day');     -- 미회전 채 만료
  delete from app.rate_limits where expires_at < now();
$$;
revoke all on function app.cleanup_auth() from public, anon, authenticated;

-- 매시 17분 실행(중복 스케줄 방지: 있으면 해제 후 재등록).
do $$
begin
  if exists (select 1 from cron.job where jobname = 'auth-cleanup') then
    perform cron.unschedule('auth-cleanup');
  end if;
end $$;
select cron.schedule('auth-cleanup', '17 * * * *', $$select app.cleanup_auth();$$);
