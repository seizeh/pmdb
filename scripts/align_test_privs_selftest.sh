#!/usr/bin/env bash
# ============================================================================
# 권한 정렬 도구(align_test_privs.py) 자체 검증 — replay_check.sh 뒤에 돈다.
#
#   ./scripts/align_test_privs_selftest.sh "<postgres 연결문자열>"
#
# 재현하려는 상황은 "스냅샷을 새 Supabase 프로젝트에 복원해서 세운 테스트 서버" 다.
#
#   1) 새 DB 에 '새 프로젝트의 기본 권한'(public 의 테이블·함수·시퀀스 →
#      anon·authenticated·service_role 에 ALL)을 먼저 걸고 prelude → schema.sql 복원
#      → 운영에서 회수한 권한이 되살아난 DB 가 된다
#   2) 대조 — 차이가 '나는지' 를 단언한다. 상황이 재현되지 않으면 3)·4) 는 아무것도
#      증명하지 못한다.
#   3) 도구로 리플레이 DB(= 운영과 같은 ACL)에 맞춘다
#   4) 다시 대조해 차이가 0 인지, 실제로 열려 있던 것들이 닫혔는지 잰다
#
# 기준으로 쓰는 리플레이 DB 는 replay_check.sh 가 만들어 둔 것이다(읽기만 한다).
#
# ⚠ 작업용 DB(pmdb_privtest)를 drop 후 재생성한다. 운영 연결문자열을 넘기지 말 것.
# ============================================================================
set -euo pipefail

ADMIN_URL="${1:?사용법: align_test_privs_selftest.sh <db-url>}"
REPLAY_DB="${REPLAY_DB:-pmdb_replay}"
TARGET_DB="${PRIVTEST_DB:-pmdb_privtest}"
cd "$(dirname "$0")/.."
export PATH="/usr/lib/postgresql/17/bin:/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"

# 같은 서버의 다른 DB 로 연결문자열을 갈아끼운다(replay_check.sh 와 같은 규칙).
url_for() {
  local base="${ADMIN_URL%%\?*}" query=""
  [ "$base" != "$ADMIN_URL" ] && query="?${ADMIN_URL#*\?}"
  echo "${base%/*}/$1${query}"
}
SRC="$(url_for "$REPLAY_DB")"
TGT="$(url_for "$TARGET_DB")"
# 확장 테이블 권한은 수퍼유저로만 줄 수 있다 — replay_check.sh 의 apply_as_superuser 와 같다.
TGT_SU="$(sed -E "s#^([a-z]+://)[^:/@]+#\\1${REPLAY_SUPERUSER:-supabase_admin}#" <<<"$TGT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

apply()    { psql "$1" -X -q -v ON_ERROR_STOP=1 -f "$2"; }
q()        { psql "$TGT" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }
fail()     { echo "❌ $*"; exit 1; }
run_tool() { ALIGN_SOURCE_DB_URL="$SRC" ALIGN_TARGET_DB_URL="$TGT" ./scripts/align_test_privs.py "$@"; }
expect() {   # expect <설명> <기대값> <SQL>
  local got
  got="$(q "$3")"
  [ "$got" = "$2" ] || fail "$1 — 기대 '$2', 실제 '$got'"
  echo "   ok  $1"
}

echo "== 1/4 권한이 풀린 대상 DB 만들기 ($TARGET_DB)"
psql "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 \
  -c "drop database if exists ${TARGET_DB} with (force)" \
  -c "create database ${TARGET_DB}"
apply "$TGT" supabase/schema/prelude.sql
apply "$TGT_SU" supabase/schema/replay-platform-grants.sql
# 새 Supabase 프로젝트의 public 기본 권한(2026-11-11 테스트 프로젝트 실측, defaclrole=postgres).
# 이게 스냅샷 복원보다 '먼저' 걸려 있다는 점이 전부다.
psql "$TGT" -X -q -v ON_ERROR_STOP=1 <<'SQL'
alter default privileges for role postgres in schema public
  grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to postgres, anon, authenticated, service_role;
SQL
apply "$TGT" supabase/schema/schema.sql

echo "== 2/4 대조 — 차이가 나야 한다"
set +e
run_tool > "$WORK/before.txt" 2>&1
rc=$?
set -e
sed -n '1,8p' "$WORK/before.txt"
[ "$rc" -eq 1 ] || { cat "$WORK/before.txt"; fail "대조가 exit 1 이 아니다(rc=$rc) — 권한이 풀린 상황이 재현되지 않았다"; }
expect "재현: 서버 전용 함수가 anon 에게 열려 있다" t \
  "select has_function_privilege('anon', 'public.get_login_user(text)', 'EXECUTE')"
expect "재현: users 의 비공개 컬럼이 anon 에게 읽힌다" t \
  "select has_column_privilege('anon', 'public.users', 'password_hash', 'SELECT')"
expect "재현: 가드 트리거가 없다" 0 \
  "select count(*) from pg_trigger where tgrelid = 'public.spatial_ref_sys'::regclass and tgname = 'spatial_ref_sys_guard'"

echo "== 3/4 적용"
run_tool --apply --out "$WORK/out" > "$WORK/apply.txt" 2>&1 || { cat "$WORK/apply.txt"; fail "적용 실패"; }
sed -n '/리허설/,$p' "$WORK/apply.txt"

echo "== 4/4 재대조 + 실측"
run_tool > "$WORK/after.txt" 2>&1 || { cat "$WORK/after.txt"; fail "적용 뒤에도 권한 차이가 남았다"; }
tail -1 "$WORK/after.txt"
expect "서버 전용 함수: anon 실행 불가" f \
  "select has_function_privilege('anon', 'public.get_login_user(text)', 'EXECUTE')"
expect "서버 전용 함수: authenticated 실행 불가" f \
  "select has_function_privilege('authenticated', 'public.get_login_user(text)', 'EXECUTE')"
expect "서버 전용 함수: service_role 은 그대로" t \
  "select has_function_privilege('service_role', 'public.get_login_user(text)', 'EXECUTE')"
expect "익명 공개 RPC 는 그대로 열려 있다" t \
  "select has_function_privilege('anon', 'public.check_username_available(text)', 'EXECUTE')"
expect "users 비공개 컬럼: anon 읽기 불가" f \
  "select has_column_privilege('anon', 'public.users', 'password_hash', 'SELECT')"
expect "users 공개 컬럼: anon 읽기 가능" t \
  "select has_column_privilege('anon', 'public.users', 'nickname', 'SELECT')"
expect "posts: anon 직접 삭제 불가" f \
  "select has_table_privilege('anon', 'public.posts', 'DELETE')"
expect "posts: authenticated TRUNCATE 불가" f \
  "select has_table_privilege('authenticated', 'public.posts', 'TRUNCATE')"
expect "가드 트리거가 걸렸다" 1 \
  "select count(*) from pg_trigger where tgrelid = 'public.spatial_ref_sys'::regclass and tgname = 'spatial_ref_sys_guard'"
# 기본 권한 — 앞으로 만드는 함수가 다시 열리지 않는지, 실제로 하나 만들어 본다(롤백).
expect "새로 만든 함수: anon·authenticated 실행 불가" "false false" \
  "begin; create function public._align_probe() returns integer language sql as 'select 1'; select has_function_privilege('anon', 'public._align_probe()', 'EXECUTE')::text || ' ' || has_function_privilege('authenticated', 'public._align_probe()', 'EXECUTE')::text; rollback;"

echo "✅ 권한 정렬 도구 자체 검증 통과"
