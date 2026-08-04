-- notifications 를 supabase_realtime publication 에 넣는다 — **운영에는 이미 있다.**
--
-- ── 왜 이제 와서
-- 운영 DB 의 publication 에는 chat_messages 와 notifications 둘 다 들어 있는데,
-- 마이그레이션에는 chat_messages 한 줄뿐이다(20260608071651). notifications 는
-- 어느 시점에 **마이그레이션 없이 직접** 추가됐고, 아무도 모르고 있었다.
--
-- 리플레이 CI 가 이걸 못 잡은 이유는 대조 대상이 public·app 스키마뿐이기 때문이다
-- (`pg_dump -n public -n app`). publication 은 데이터베이스 레벨 객체라 그 밖에 있다.
-- 같은 이유로 storage RLS 정책과 cron 잡도 대조 밖이었다 — 이 PR 이 함께 메운다.
--
-- ── 무엇이 깨져 있었나
-- 마이그레이션만으로 세운 DB(CI 리플레이, 재해복구, 스테이징)에서는 notifications
-- 가 publication 에 없다. 그러면 앱의 `rt:notifications:<uid>` 구독이 **오류 없이
-- 조용히 아무 이벤트도 못 받는다** — 벨 배지·알림 목록 라이브 갱신·포그라운드
-- 알림이 전부 죽는데 구독은 성공으로 보인다. 운영에서는 정상이라 드러나지 않았다.
--
-- 운영에는 이미 있으므로 이 마이그레이션은 그쪽에서 무동작이다. 목적은 **저장소가
-- 운영을 재현할 수 있게** 만드는 것이다.
do $$
begin
  if not exists (
    select 1
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c       on c.oid = pr.prrelid
      join pg_namespace n   on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime'
       and n.nspname = 'public'
       and c.relname = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
