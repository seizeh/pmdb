#!/usr/bin/env bash
# ============================================================================
# PawMate 수동 백업 스크립트 (Supabase Free 요금제용)
#
#  · DB 를 pg_dump 커스텀 포맷으로 덤프(public·app 스키마만) → (선택) gpg 대칭 암호화
#    - 실데이터는 전부 public+app 에 있고(커스텀 인증이라 auth 스키마 미사용),
#      auth/storage/realtime/vault/cron 등 Supabase 내부 스키마는 덤프에서 제외한다.
#      (내부 스키마까지 담으면 새 프로젝트 복원 시 supabase_admin 소유 객체 충돌로 실패)
#    - GRANT 는 유지(--no-owner 만, --no-privileges 아님): 베이스 스키마 그랜트가
#      마이그레이션에 없고 out-of-band 로 적용된 구조라, 덤프에 그랜트가 있어야 복원본이
#      anon/authenticated/service_role 권한을 자급자족한다.
#  · 덤프 직후 무결성 검증(pg_restore --list): "생성됨"과 "복원 가능"은 다르므로.
#  · (선택) Storage 버킷을 rclone(S3 호환)으로 로컬에 동기화.
#  · 보존주기(기본 7일) 지난 백업 자동 폐기 — 06운영점검주기.md 백업 정책과 연동.
#
# 사용법: scripts/backup.env 에 SUPABASE_DB_URL(세션 풀러 5432)·BACKUP_PASSPHRASE 설정 후 실행.
#         (backup.command 더블클릭 또는 ./scripts/backup.sh)
#
# 복원(참고) — 새 Supabase 프로젝트 기준:
#   1) 필요한 확장 먼저 설치: create extension postgis, pg_cron, pgcrypto 등
#      (-n 스키마 제한 덤프에는 CREATE EXTENSION 이 안 담기므로 PostGIS 등이 먼저 있어야 함)
#   2) 복호화(암호화본이면):  gpg -d db_YYYYMMDD_HHMMSS.dump.gpg > restore.dump
#   3) 복원:  pg_restore --no-owner -d "<대상 세션풀러 연결문자열>" restore.dump
#      (덤프에 public·app 의 스키마·데이터·GRANT·RLS 가 모두 포함되어 자급자족)
#   4) cron 잡(cron 스키마)은 덤프 범위 밖 → supabase/migrations 의 pg_cron 설정을 재적용.
#      Storage 이미지 파일은 rclone 백업본에서 별도 복원(스토리지에 재업로드).
# ============================================================================
set -euo pipefail

# --- 설정 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/../backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
STAMP="$(date +%Y%m%d_%H%M%S)"   # 초까지 — 같은 분 재실행 시 덮어쓰기 방지

log() { printf '[backup %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[backup] 오류: %s\n' "$*" >&2; exit 1; }

# --- 사전 점검 ----------------------------------------------------------
[ -n "${SUPABASE_DB_URL:-}" ] || die "SUPABASE_DB_URL 미설정 (세션 풀러 5432 연결문자열 필요)"
command -v pg_dump    >/dev/null 2>&1 || die "pg_dump 없음 (libpq/postgresql-client 설치 필요)"
command -v pg_restore >/dev/null 2>&1 || die "pg_restore 없음 (무결성 검증에 필요)"

mkdir -p "$BACKUP_DIR"
DUMP_ARGS=(-Fc --no-owner -n public -n app -d "$SUPABASE_DB_URL")

# --- 1) DB 덤프 (+무결성 검증), 암호화 시 파이프로 평문 디스크 미접촉 ---
if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
  command -v gpg >/dev/null 2>&1 || die "gpg 없음 (BACKUP_PASSPHRASE 설정 시 필요)"
  DB_FINAL="$BACKUP_DIR/db_${STAMP}.dump.gpg"
  log "DB 덤프→암호화(public·app) → $DB_FINAL"
  # 패스프레이즈는 fd 3 으로 전달(argv 노출·ps 노출 없음). 평문 덤프 파일은 생성하지 않음.
  pg_dump "${DUMP_ARGS[@]}" \
    | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 -c -o "$DB_FINAL" 3<<<"$BACKUP_PASSPHRASE"
  log "무결성 검증(복호화 → 아카이브 목차)"
  gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 -d "$DB_FINAL" 3<<<"$BACKUP_PASSPHRASE" \
    | pg_restore --list >/dev/null || die "덤프 무결성 검증 실패(암호화본 손상/절단)"
else
  log "⚠ BACKUP_PASSPHRASE 미설정 — 평문으로 저장됩니다(운영 시 암호화 권장)"
  DB_FINAL="$BACKUP_DIR/db_${STAMP}.dump"
  log "DB 덤프(public·app) → $DB_FINAL"
  pg_dump "${DUMP_ARGS[@]}" -f "$DB_FINAL"
  log "무결성 검증(아카이브 목차)"
  pg_restore --list "$DB_FINAL" >/dev/null || die "덤프 무결성 검증 실패(손상/절단)"
fi
log "DB 백업 산출물: $DB_FINAL ($(du -h "$DB_FINAL" | cut -f1))"

# --- 2) (선택) Storage 동기화 (원격 → 로컬) -----------------------------
if [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
  command -v rclone >/dev/null 2>&1 || die "rclone 없음 (BACKUP_RCLONE_REMOTE 설정 시 필요)"
  STORAGE_DIR="$BACKUP_DIR/storage_${STAMP}"
  log "Storage 동기화 → $STORAGE_DIR"
  rclone sync "$BACKUP_RCLONE_REMOTE" "$STORAGE_DIR"
  log "Storage 동기화 완료"
else
  log "Storage 백업 건너뜀 (BACKUP_RCLONE_REMOTE 미설정 — 이미지 파일은 별도 백업 필요)"
fi

# --- 3) 보존주기 폐기 ---------------------------------------------------
log "보존 ${RETENTION_DAYS}일 초과 백업 폐기"
find "$BACKUP_DIR" -maxdepth 1 -name 'db_*.dump*' -type f -mtime "+$RETENTION_DAYS" -print -delete || true
find "$BACKUP_DIR" -maxdepth 1 -name 'storage_*'  -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

log "백업 완료. 보관 위치: $BACKUP_DIR"
log "※ 이 폴더는 비공개로 유지하고, 폐기 사실을 06운영점검주기.md 점검 이력란에 기록하세요."
