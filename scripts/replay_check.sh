#!/usr/bin/env bash
# ============================================================================
# 마이그레이션 리플레이 검증 — 빈 DB 에 처음부터 다시 쌓아 스냅샷과 대조한다.
#
#   ./scripts/replay_check.sh "<postgres 연결문자열>"
#
# 작업용 DB 두 개를 새로 만들어 같은 조건에서 각각 채운 뒤, 양쪽을 pg_dump 해서 비교한다.
#
#   A(스냅샷)  prelude → schema.sql
#   B(리플레이) prelude → replay-stubs → baseline.sql → replay-default-privs → migrations/*.sql
#
# 스냅샷을 파일 그대로 비교하지 않고 A 로 한 번 복원했다 다시 덤프하는 이유:
# pg_dump 출력은 되먹였을 때 글자 그대로 재현되지 않는다. 예컨대
#   check (status in ('a','b'))  →  = ANY ((ARRAY['a','b'])::text[])        (운영)
# 이 텍스트를 다시 파싱하면 파서가 배열 캐스트를 원소별로 접어
#   = ANY (ARRAY[('a')::text, ('b')::text])                                  (복원 후)
# 로 바뀐다. 의미는 같은데 글자가 다르다. 양쪽 모두 복원→덤프를 거치게 하면 이런
# 왕복 아티팩트가 상쇄되고 진짜 스키마 차이만 남는다.
#
# 통과하면 두 가지가 보장된다.
#   ① 재현성 — 이 저장소만 받아서 빈 DB 에 올리면 현재 스키마가 나온다.
#   ② 드리프트 감지 — 마이그레이션 없이 운영 DB 에 직접 친 DDL(psql 직행)이나
#      갱신을 잊은 스냅샷이 있으면 diff 로 드러난다.
#
# 리플레이 DB 이름은 서버의 cron.database_name 과 같아야 한다(pg_cron 은 그 DB 에서만
# create extension 이 된다). CI 가 맞춰 주고, 로컬은 README 의 docker 예시 참고.
#
# ⚠ 작업용 DB 두 개는 매번 drop 후 재생성한다. 운영 연결문자열을 넘기지 말 것.
# ============================================================================
set -euo pipefail

ADMIN_URL="${1:?사용법: replay_check.sh <db-url>}"
REPLAY_DB="${REPLAY_DB:-pmdb_replay}"
SNAPSHOT_DB="${SNAPSHOT_DB:-pmdb_snapshot}"
cd "$(dirname "$0")/.."
export PATH="/usr/lib/postgresql/17/bin:/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"
. scripts/_schema_dump.sh

# 같은 서버의 다른 DB 로 연결문자열을 갈아끼운다(쿼리스트링은 유지).
url_for() {
  local base="${ADMIN_URL%%\?*}" query=""
  [ "$base" != "$ADMIN_URL" ] && query="?${ADMIN_URL#*\?}"
  echo "${base%/*}/$1${query}"
}
REPLAY_URL="$(url_for "$REPLAY_DB")"
SNAPSHOT_URL="$(url_for "$SNAPSHOT_DB")"

SCHEMA_DIR=supabase/schema
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

apply() { psql "$1" -X -q -v ON_ERROR_STOP=1 -f "$2"; }

echo "== 1/5 작업용 DB 재생성 ($SNAPSHOT_DB, $REPLAY_DB)"
psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 \
  -c "drop database if exists ${SNAPSHOT_DB} with (force)" \
  -c "drop database if exists ${REPLAY_DB} with (force)" \
  -c "create database ${SNAPSHOT_DB}" \
  -c "create database ${REPLAY_DB}"

# A 에는 replay-stubs 를 적용하지 않는다. 스텁의 기본 권한(ALTER DEFAULT PRIVILEGES)은
# '마이그레이션이 만든 객체가 운영에서 어떤 ACL 을 갖게 되는지' 를 재현하는 장치라
# 리플레이 쪽에만 필요하다. 스냅샷은 이미 그 결과(GRANT 문)를 담고 있으므로,
# A 에 기본 권한을 걸면 그 위에 또 얹혀 운영보다 넓은 권한이 되어 버린다.
echo "== 2/5 A: 스냅샷 복원"
apply "$SNAPSHOT_URL" "$SCHEMA_DIR/prelude.sql"
apply "$SNAPSHOT_URL" "$SCHEMA_DIR/schema.sql"

echo "== 3/5 B: 베이스라인 + 마이그레이션 리플레이"
apply "$REPLAY_URL" "$SCHEMA_DIR/prelude.sql"
apply "$REPLAY_URL" "$SCHEMA_DIR/replay-stubs.sql"
apply "$REPLAY_URL" "$SCHEMA_DIR/baseline.sql"
# 기본 권한은 베이스라인 '다음' 에 건다 — 이유는 그 파일 주석 참고.
apply "$REPLAY_URL" "$SCHEMA_DIR/replay-default-privs.sql"
count=0
for f in supabase/migrations/*.sql; do
  if ! out=$(psql "$REPLAY_URL" -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1); then
    echo "$out"
    echo "-- 실패: $f"
    exit 1
  fi
  count=$((count + 1))
done
echo "   적용 $count 건"

echo "== 4/5 양쪽 덤프"
dump_schema_to "$SNAPSHOT_URL" "$WORK/snapshot.sql"
dump_schema_to "$REPLAY_URL" "$WORK/replayed.sql"
normalize_dump "$WORK/snapshot.sql" > "$WORK/a.sql"
normalize_dump "$WORK/replayed.sql" > "$WORK/b.sql"

echo "== 5/5 대조"
# 전체 diff 는 파일로 남긴다(CI 는 아티팩트로 올린다) — 콘솔은 잘리기 때문에.
OUT_DIFF="${REPLAY_DIFF_OUT:-replay-diff.txt}"

if diff -u "$WORK/a.sql" "$WORK/b.sql" > "$WORK/diff.txt"; then
  echo "✅ 리플레이 결과가 스냅샷과 일치 ($(wc -l < "$WORK/b.sql" | tr -d ' ') 줄)"
  : > "$OUT_DIFF"

  # ── public·app 밖 대조 ────────────────────────────────────────────────────
  # 여기는 스냅샷 DB 와 비교할 수 없다 — schema.sql 에 이 객체들이 없어서
  # 복원해도 아무것도 안 생긴다. 그래서 **커밋된 파일(운영에서 뽑은 것)** 과
  # 리플레이 DB 를 직접 댄다. baseline.sql 과 같은 성격의 생성물이다.
  OOB_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../supabase/schema/outofband.txt"
  if [ -f "$OOB_FILE" ]; then
    echo "== 5b/5 퍼블리케이션·storage·cron 대조"
    dump_outofband_to "$REPLAY_URL" "$WORK/oob_replay.txt"
    if diff -u "$OOB_FILE" "$WORK/oob_replay.txt" > "$WORK/oob_diff.txt"; then
      echo "✅ 퍼블리케이션·storage·cron 도 일치 ($(wc -l < "$WORK/oob_replay.txt" | tr -d ' ') 줄)"
      exit 0
    fi
    cat "$WORK/oob_diff.txt" >> "$OUT_DIFF"
    echo "❌ public·app **밖** 객체가 다름 — 스키마는 맞는데 여기서 갈렸다."
    echo "   대상: supabase_realtime 퍼블리케이션 · storage 버킷/정책 · cron 잡"
    echo "   · 운영에 직접 친 것이면 마이그레이션으로 남길 것"
    echo "   · 마이그레이션이 맞다면 ./scripts/dump_schema.sh 로 스냅샷 갱신"
    echo
    echo "(-- 는 커밋된 파일=운영에만, ++ 는 리플레이 결과에만)"
    cat "$WORK/oob_diff.txt"
    exit 1
  fi
  echo "⚠️  supabase/schema/outofband.txt 가 없어 밖 객체 대조를 건너뜀"
  exit 0
fi

cp "$WORK/diff.txt" "$OUT_DIFF"
echo "❌ 리플레이 결과가 스냅샷과 다름 — 아래 중 하나다:"
echo "   · 마이그레이션 없이 운영 DB 에 직접 친 DDL 이 있다 → 마이그레이션으로 남길 것"
echo "   · 스냅샷 갱신을 잊었다 → ./scripts/dump_schema.sh"
echo "   · 베이스라인이 어긋났다 → ./scripts/build_baseline.py"
echo
echo "(-- 는 스냅샷=운영에만, ++ 는 리플레이 결과에만 있는 줄)"
echo "전체 diff: $OUT_DIFF"
echo
sed -n '1,150p' "$WORK/diff.txt"
total=$(grep -cE '^[-+][^-+]' "$WORK/diff.txt" || true)
echo
echo "… (앞 150줄만 표시) 차이 있는 줄 $total 개"
exit 1
