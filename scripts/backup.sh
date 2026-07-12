#!/usr/bin/env bash
# ============================================================================
# PawMate 수동 백업 스크립트 (Supabase Free 요금제용)
#
#  · DB(Postgres) 를 pg_dump 커스텀 포맷으로 덤프 → (선택) gpg 대칭 암호화
#  · (선택) Storage 버킷을 rclone(S3 호환)으로 동기화
#  · 보존주기(기본 7일) 지난 백업 자동 폐기 — 삭제/탈퇴 데이터가 백업에 오래 남지
#    않도록(개인정보 파기 의무). 06운영점검주기.md 백업 정책과 연동.
#
# 사용법:
#   1) 필수 환경변수 설정 (비밀은 절대 커밋 금지):
#        export SUPABASE_DB_URL='postgresql://postgres.<ref>:<PWD>@<pooler-host>:5432/postgres'
#          └ 대시보드 → Project Settings → Database → Connection string → "Session pooler"(5432)
#      선택:
#        export BACKUP_DIR="$HOME/pawmate-backups"     # 기본: 이 스크립트 옆 ./backups
#        export BACKUP_PASSPHRASE='...'                # 설정 시 덤프를 gpg -c 로 암호화(권장)
#        export RETENTION_DAYS=7                        # 보존 일수(기본 7)
#        export BACKUP_RCLONE_REMOTE='pawmate-s3:media' # 설정 시 Storage 도 동기화
#   2) 실행:  ./scripts/backup.sh
#
# 복원(참고):
#   gpg -d backups/db_YYYYMMDD_HHMM.dump.gpg > restore.dump      # 암호화본이면 복호화
#   pg_restore -d "<대상 연결문자열>" --clean --if-exists restore.dump
#   ※ pg_cron 잡·일부 확장 설정은 덤프에 안 담길 수 있으니, 복원 후 supabase/migrations 를
#     다시 적용(supabase db push)하는 것을 전제로 한다.
# ============================================================================
set -euo pipefail

# --- 설정 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/../backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
STAMP="$(date +%Y%m%d_%H%M)"

log() { printf '[backup %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[backup] 오류: %s\n' "$*" >&2; exit 1; }

# --- 사전 점검 ----------------------------------------------------------
[ -n "${SUPABASE_DB_URL:-}" ] || die "SUPABASE_DB_URL 미설정 (세션 풀러 5432 연결문자열 필요)"
command -v pg_dump >/dev/null 2>&1 || die "pg_dump 없음 (libpq/postgresql-client 설치 필요)"

mkdir -p "$BACKUP_DIR"
DB_FILE="$BACKUP_DIR/db_${STAMP}.dump"

# --- 1) DB 덤프 ---------------------------------------------------------
log "DB 덤프 시작 → $DB_FILE"
pg_dump -Fc --no-owner --no-privileges -d "$SUPABASE_DB_URL" -f "$DB_FILE"
log "DB 덤프 완료 ($(du -h "$DB_FILE" | cut -f1))"

# --- 2) (선택) 암호화 ---------------------------------------------------
if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
  command -v gpg >/dev/null 2>&1 || die "gpg 없음 (BACKUP_PASSPHRASE 설정 시 필요)"
  log "gpg 대칭 암호화"
  gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" -c "$DB_FILE"
  rm -f "$DB_FILE"                 # 평문 덤프 제거
  DB_FINAL="$DB_FILE.gpg"
else
  log "⚠ BACKUP_PASSPHRASE 미설정 — 덤프가 평문으로 저장됩니다(운영 시 암호화 권장)"
  DB_FINAL="$DB_FILE"
fi
log "DB 백업 산출물: $DB_FINAL"

# --- 3) (선택) Storage 동기화 ------------------------------------------
if [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
  command -v rclone >/dev/null 2>&1 || die "rclone 없음 (BACKUP_RCLONE_REMOTE 설정 시 필요)"
  STORAGE_DIR="$BACKUP_DIR/storage_${STAMP}"
  log "Storage 동기화 → $STORAGE_DIR"
  rclone sync "$BACKUP_RCLONE_REMOTE" "$STORAGE_DIR"
  log "Storage 동기화 완료"
else
  log "Storage 백업 건너뜀 (BACKUP_RCLONE_REMOTE 미설정 — 이미지 파일은 별도 백업 필요)"
fi

# --- 4) 보존주기 폐기 ---------------------------------------------------
log "보존 ${RETENTION_DAYS}일 초과 백업 폐기"
find "$BACKUP_DIR" -maxdepth 1 -name 'db_*.dump*'   -type f -mtime "+$RETENTION_DAYS" -print -delete || true
find "$BACKUP_DIR" -maxdepth 1 -name 'storage_*'    -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

log "백업 완료. 보관 위치: $BACKUP_DIR"
log "※ 이 폴더는 비공개로 유지하고, 폐기 사실을 06운영점검주기.md 점검 이력란에 기록하세요."
