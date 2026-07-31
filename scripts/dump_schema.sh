#!/usr/bin/env bash
# ============================================================================
# 스키마 스냅샷 생성 — DB 테스트(supabase/tests, CI)용.
#
# public·app 스키마의 구조(테이블·뷰·함수·트리거·RLS·GRANT)만 덤프한다(데이터 제외).
# 베이스 스키마가 마이그레이션 저장소 밖(out-of-band)에 있는 구조라, 테스트 DB 는
# 마이그레이션 리플레이가 아니라 이 스냅샷으로 재현한다.
#
# 갱신 시점: DB 스키마를 바꾸는 마이그레이션을 적용한 뒤 실행해 함께 커밋한다.
#   ./scripts/dump_schema.sh   (scripts/backup.env 의 SUPABASE_DB_URL 사용)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/../supabase/schema/schema.sql"

export PATH="/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"
. "$SCRIPT_DIR/_schema_dump.sh"
set -a; . "$SCRIPT_DIR/backup.env"; set +a
[ -n "${SUPABASE_DB_URL:-}" ] || { echo "SUPABASE_DB_URL 미설정" >&2; exit 1; }

dump_schema_to "$SUPABASE_DB_URL" "$OUT"
echo "written: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"

# 스냅샷이 바뀌면 베이스라인도 같이 바뀐다(= schema.sql − 마이그레이션 생성물).
# 여기서 함께 갱신해 두 파일이 어긋난 채 커밋되는 일을 막는다.
"$SCRIPT_DIR/build_baseline.py"
