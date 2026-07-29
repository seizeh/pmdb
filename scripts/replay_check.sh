#!/usr/bin/env bash
# ============================================================================
# 마이그레이션 리플레이 검증 — 빈 DB 에 처음부터 다시 쌓아 스냅샷과 대조한다.
#
#   ./scripts/replay_check.sh "<postgres 연결문자열>"
#
#   prelude.sql → replay-stubs.sql → baseline.sql → migrations/*.sql
#     == supabase/schema/schema.sql
#
# 이 등식이 성립하면 두 가지가 동시에 보장된다.
#   ① 재현성 — 이 저장소만 받아서 빈 DB 에 올리면 현재 스키마가 나온다.
#   ② 드리프트 감지 — 마이그레이션 없이 운영 DB 에 직접 친 DDL(psql 직행)이나
#      갱신을 잊은 스냅샷이 있으면 diff 로 드러난다.
#
# 넘긴 연결문자열의 DB 를 직접 쓰지 않고 그 옆에 작업용 DB($REPLAY_DB, 기본
# pmdb_replay)를 새로 만들어 거기서 돌린다. supabase/postgres 이미지의 기본 DB 에는
# storage 스키마 같은 플랫폼 객체가 이미 들어 있어 "빈 DB" 가 아니고, 그 소유자도
# postgres 가 아니라 스텁을 얹을 수 없기 때문이다.
#
# ⚠ 작업용 DB 는 매번 drop 후 재생성한다. 운영 연결문자열을 넘기지 말 것.
# ============================================================================
set -euo pipefail

ADMIN_URL="${1:?사용법: replay_check.sh <db-url>}"
REPLAY_DB="${REPLAY_DB:-pmdb_replay}"
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"
. scripts/_schema_dump.sh

# 같은 서버의 작업용 DB 로 연결문자열을 갈아끼운다(쿼리스트링은 유지).
base="${ADMIN_URL%%\?*}"
query=""
[ "$base" != "$ADMIN_URL" ] && query="?${ADMIN_URL#*\?}"
DB_URL="${base%/*}/${REPLAY_DB}${query}"

SCHEMA_DIR=supabase/schema
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 0/4 작업용 DB 재생성 ($REPLAY_DB)"
psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 \
  -c "drop database if exists ${REPLAY_DB} with (force)" \
  -c "create database ${REPLAY_DB}"

psql_run() { psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "== 1/4 준비 (확장·롤·플랫폼 스텁)"
psql_run -f "$SCHEMA_DIR/prelude.sql"
psql_run -f "$SCHEMA_DIR/replay-stubs.sql"

echo "== 2/4 베이스라인 (저장소 밖에 있던 기반 스키마)"
psql_run -f "$SCHEMA_DIR/baseline.sql"

echo "== 3/4 마이그레이션 리플레이"
count=0
for f in supabase/migrations/*.sql; do
  if ! out=$(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1); then
    echo "$out"
    echo "-- 실패: $f"
    exit 1
  fi
  count=$((count + 1))
done
echo "   적용 $count 건"

echo "== 4/4 스냅샷 대조"
dump_schema_to "$DB_URL" "$WORK/replayed.sql"
normalize_dump "$WORK/replayed.sql"          > "$WORK/a.sql"
normalize_dump "$SCHEMA_DIR/schema.sql"      > "$WORK/b.sql"

if diff -u "$WORK/b.sql" "$WORK/a.sql" > "$WORK/diff.txt"; then
  echo "✅ 리플레이 결과가 스냅샷과 일치 ($(wc -l < "$WORK/a.sql" | tr -d ' ') 줄)"
  exit 0
fi

echo "❌ 리플레이 결과가 스냅샷과 다름 — 아래 중 하나다:"
echo "   · 마이그레이션 없이 운영 DB 에 직접 친 DDL 이 있다 → 마이그레이션으로 남길 것"
echo "   · 스냅샷 갱신을 잊었다 → ./scripts/dump_schema.sh"
echo "   · 베이스라인이 어긋났다 → ./scripts/build_baseline.py"
echo
echo "(-- 는 스냅샷에만, ++ 는 리플레이 결과에만 있는 줄)"
head -400 "$WORK/diff.txt"
total=$(grep -cE '^[-+][^-+]' "$WORK/diff.txt" || true)
echo
echo "차이 있는 줄 $total 개"
exit 1
