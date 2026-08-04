#!/usr/bin/env bash
# 스키마 덤프 공통부 — dump_schema.sh(운영 → 스냅샷 갱신)와
# replay_check.sh(리플레이 결과 → 스냅샷 대조)가 같이 쓴다.
#
# 두 곳이 서로 다른 필터를 쓰면 없는 차이가 보이므로 반드시 여기 한 곳만 고칠 것.

# dump_schema_to <db-url> <out-file>
dump_schema_to() {
  local db_url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  # 필터:
  #  · 'Dumped from/by' 주석·\restrict 토큰 — 실행마다 달라져 diff 소음
  #  · CREATE SCHEMA public — 새 DB 에 이미 존재해 복원이 실패한다(app 은 유지)
  #  · ALTER DEFAULT PRIVILEGES — 타 롤(supabase_admin 등) 기본권한은 비수퍼유저
  #    복원에서 permission denied. 객체별 GRANT 는 그대로 담기므로 테스트에 불필요.
  pg_dump "$db_url" --schema-only --no-owner -n public -n app \
    | grep -vE '^-- Dumped |^\\|^CREATE SCHEMA public;$|^ALTER DEFAULT PRIVILEGES ' \
    > "$out"
}

# 비교용 정규화.
#  · 첫 객체 블록(`-- Name: …`) 앞의 머리말을 떼어낸다 — SET 문 뿐이고 pg_dump
#    마이너 버전에 따라 줄이 늘고 줄어 스키마와 무관한 차이를 만든다.
#  · IN 목록의 두 가지 표기를 한 꼴로 모은다(normalize_schema.py 주석 참고).
normalize_dump() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  awk 'f || /^-- Name: /{f=1; print}' "$1" | python3 "$here/normalize_schema.py"
}

# ── public·app 밖의 객체 스냅샷 ──────────────────────────────────────────────
#
# pg_dump 는 `-n public -n app` 으로 제한돼 있어 **마이그레이션이 만드는 다음 것들을
# 아무도 대조하지 않았다**:
#
#   · supabase_realtime publication 멤버십  (realtime 구독이 실제로 도착하는지)
#   · storage.buckets 설정                   (공개 여부·용량·MIME 제한)
#   · storage.objects RLS 정책               (사용자 사진의 접근 제어)
#   · cron.job                               (보존기간 파기 배치)
#
# 즉 "마이그레이션 없이 친 DDL 을 즉시 잡는다" 는 이 저장소의 보증이 **사진 접근
# 제어와 파기 배치에는 적용되지 않았다**. 실제로 publication 드리프트가 하나 있었고
# (notifications, 20260804120000) 그동안 아무도 몰랐다.
#
# 이 스키마들을 pg_dump 대상에 넣지 않는 이유: 확장·플랫폼이 만든 객체가 대부분이고
# 소유자도 supabase_admin 이라, 맨바닥 컨테이너에서 재현되지 않아 diff 가 소음으로
# 가득 찬다. 그래서 **우리가 만든 것만** 골라 텍스트로 뽑아 비교한다.
#
# 정렬을 고정해 실행 순서에 따른 차이를 없앤다.
#
# dump_outofband_to <db-url> <out-file>
dump_outofband_to() {
  local db_url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  psql "$db_url" -X -q -t -A --no-psqlrc -v ON_ERROR_STOP=1 -f /dev/stdin > "$out" <<'SQL'
\pset footer off
select 'PUBLICATION supabase_realtime  ' || n.nspname || '.' || c.relname
  from pg_publication p
  join pg_publication_rel pr on pr.prpubid = p.oid
  join pg_class c            on c.oid = pr.prrelid
  join pg_namespace n        on n.oid = c.relnamespace
 where p.pubname = 'supabase_realtime'
   and n.nspname in ('public', 'app')
 order by 1;

select 'BUCKET ' || id
       || '  public=' || public::text
       || '  size_limit=' || coalesce(file_size_limit::text, '-')
       || '  mime=' || coalesce(array_to_string(allowed_mime_types, ','), '-')
  from storage.buckets order by id;

select 'STORAGE POLICY ' || policyname
       || '  cmd=' || cmd
       || '  roles=' || roles::text
       || '  qual=' || coalesce(qual, '-')
       || '  check=' || coalesce(with_check, '-')
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
 order by policyname;

select 'CRON ' || jobname
       || '  [' || schedule || ']'
       || '  active=' || active::text
       || '  :: ' || regexp_replace(btrim(command), '\s+', ' ', 'g')
  from cron.job order by jobname;
SQL
}
