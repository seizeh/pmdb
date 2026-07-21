#!/usr/bin/env bash
# ============================================================================
# DB 테스트 러너 — supabase/tests/*_test.sql(pgTAP)을 대상 DB 에서 실행한다.
#   ./scripts/run_db_tests.sh "<postgres 연결문자열>"
#
# 각 테스트 파일은 begin ... rollback 으로 자급자족(시드 포함, 데이터 안 남김)이라
# 프로덕션에 직접 돌려도 안전하다. pg_prove 없이 psql 만 필요:
#   · SQL 에러(ON_ERROR_STOP) 또는 pgTAP 'not ok' 출력 시 실패(exit 1).
# ============================================================================
set -uo pipefail

DB_URL="${1:?사용법: run_db_tests.sh <db-url>}"
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"

fail=0
for f in supabase/tests/*_test.sql; do
  echo "== $f"
  if ! out=$(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$f" 2>&1); then
    echo "$out"
    echo "-- SQL 오류: $f"
    fail=1
    continue
  fi
  echo "$out"
  if grep -q '^not ok' <<<"$out"; then
    echo "-- 단언 실패: $f"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then echo "✅ 모든 DB 테스트 통과"; else echo "❌ 실패한 DB 테스트 있음"; fi
exit $fail
