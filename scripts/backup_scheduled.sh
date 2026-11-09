#!/usr/bin/env bash
# ============================================================================
# PawMate 백업 예약 실행 진입점 (launchd 전용)
#
# launchd 가 30분마다 이 스크립트를 부르고, 아래 조건이 모두 맞을 때만 backup.sh 를 돌린다.
#   ① 만기   — 마지막 성공(backups/.last_success)이 BACKUP_EVERY_DAYS(기본 6일) 이상 지남
#   ② 재시도 간격 — 마지막 시도(backups/.last_attempt)가 BACKUP_RETRY_HOURS(기본 3시간) 이상 지남
#   ③ 완전히 깨어 있음 — pmset systemstate 에 Graphics 가 있음(DarkWake 에는 없다)
#   ④ 네트워크 — DB 풀러에 TCP 연결 가능
# 조건 미달은 실패가 아니다. 핑 없이 끝내고 다음 차례에 다시 본다. 오래 못 돌면
# healthchecks(주기 7일·유예 1일)가 "미실행" 으로 알린다.
#
# 왜 정각 예약(StartCalendarInterval 월 09:30)을 버렸나: 맥이 덮개 닫힌 채 잠든 시각에
# 걸리면 launchd 는 다음 DarkWake(2~5초짜리 유지보수 깨어남)에 작업을 띄운다. 그때는
# 네트워크가 없거나 곧 다시 잠든다 — 2026-10-12~11-09 예약 실행 5회 전부 실패
# (DNS 실패 4회, 덤프 도중 재잠자기 1회). "정해진 때 한 번" 대신 "자주 묻고 될 때 한다".
# 6일인 이유: 하트비트 주기(7일) 안에 성공 핑이 들어오도록 하루 여유를 둔다.
# 재시도 간격을 두는 이유: 진짜 실패(DB 장애·사본 폴더 오류)가 30분마다 덤프를 쌓지 않게.
#
# 설치(~/Library/LaunchAgents/kr.pawmate.backup.plist, 경로는 이 저장소 위치로):
#   <key>Label</key><string>kr.pawmate.backup</string>
#   <key>ProgramArguments</key><array>
#     <string>/bin/bash</string><string>/절대경로/pmdb/scripts/backup_scheduled.sh</string></array>
#   <key>StartInterval</key><integer>1800</integer>
#   <key>RunAtLoad</key><true/>
#   <key>StandardOutPath</key><string>/절대경로/pmdb/backups/backup.log</string>
#   <key>StandardErrorPath</key><string>/절대경로/pmdb/backups/backup.log</string>
# 적용: launchctl bootout gui/$UID/kr.pawmate.backup; launchctl bootstrap gui/$UID <plist>
# 검증: launchctl kickstart gui/$UID/kr.pawmate.backup 후 launchctl print 의 last exit code
#       와 backup.log 를 본다(대화형 셸 수동 실행은 launchd 경로 검증이 아니다).
# ============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
[ -f ./backup.env ] || { echo "[sched] 오류: backup.env 없음 ($SCRIPT_DIR)" >&2; exit 1; }
set -a; . ./backup.env; set +a
set -u

BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/../backups}"
EVERY_DAYS="${BACKUP_EVERY_DAYS:-6}"
RETRY_HOURS="${BACKUP_RETRY_HOURS:-3}"
OK_MARK="$BACKUP_DIR/.last_success"   # backup.sh 가 성공 시 갱신(수동 실행 포함)
TRY_MARK="$BACKUP_DIR/.last_attempt"  # 이 스크립트가 backup.sh 를 띄우기 직전 갱신

log() { printf '[sched %s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*"; }
age_sec() { echo $(( $(date +%s) - $(stat -f %m "$1") )); }

# ① 만기 전이면 조용히 끝낸다(30분마다 도는 일상 경로 — 로그를 남기지 않는다).
if [ -f "$OK_MARK" ] && [ "$(age_sec "$OK_MARK")" -lt $(( EVERY_DAYS * 86400 )) ]; then
  exit 0
fi
# ② 직전 시도가 실패한 지 얼마 안 됐으면 기다린다.
if [ -f "$TRY_MARK" ] && [ "$(age_sec "$TRY_MARK")" -lt $(( RETRY_HOURS * 3600 )) ]; then
  exit 0
fi
# ③ DarkWake 면 건너뛴다 — 몇 초 뒤 다시 잠들어 덤프가 중간에 끊긴다(11-09 실측).
if ! /usr/bin/pmset -g systemstate 2>/dev/null | grep -q 'Graphics'; then
  log "⏸ 백업 만기지만 맥이 잠깐 깨어난 상태(DarkWake) — 다음 차례에 다시 확인"
  exit 0
fi
# ④ DB 풀러에 닿지 않으면 건너뛴다. 연결문자열의 마지막 @ 뒤가 host[:port].
#    연결문자열이 비었으면 여기서 판단하지 않는다 — backup.sh 가 오류와 /fail 핑으로 알린다.
if [ -n "${SUPABASE_DB_URL:-}" ]; then
  hp="${SUPABASE_DB_URL##*@}"; hp="${hp%%[/?]*}"
  db_host="${hp%%:*}"; db_port="${hp##*:}"; [ "$db_port" != "$hp" ] || db_port=5432
  if ! /usr/bin/nc -z -G 5 "$db_host" "$db_port" >/dev/null 2>&1; then
    log "⏸ 백업 만기지만 DB 에 연결할 수 없음($db_host:$db_port) — 다음 차례에 다시 확인"
    exit 0
  fi
fi

mkdir -p "$BACKUP_DIR"
touch "$TRY_MARK"
log "▶ 백업 만기(마지막 성공 ${EVERY_DAYS}일 경과 또는 기록 없음) — backup.sh 실행"
exec bash ./backup.sh
