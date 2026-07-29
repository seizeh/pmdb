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

# 비교용 정규화 — 첫 객체 블록(`-- Name: …`) 앞의 머리말을 떼어낸다.
# 머리말은 SET 문 뿐이고 pg_dump 마이너 버전에 따라 줄이 늘고 줄어서
# 스키마와 무관한 차이를 만든다.
normalize_dump() {
  awk 'f || /^-- Name: /{f=1; print}' "$1"
}
