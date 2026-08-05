#!/usr/bin/env bash
# ============================================================================
# 주간 운영 점검 — 읽기 전용. 매주 한 번 실행해 조치가 필요한 것만 ⚠ 로 띄운다.
#
#   ./scripts/weekly_check.sh
#
# 연결은 backup.env 의 운영 연결문자열(SUPABASE_DB_URL)을 그대로 쓴다.
# 아무것도 변경하지 않는다 — 드리프트 보정 등은 안내만 하고 실행은 사람이 한다.
#
# 점검 항목:
#   ① 미처리 신고(App Store 1.2 — 24시간 내 조치 의무)
#   ② 클라이언트 오류 최근 7일 상위 유형
#   ③ 크론 실패 이력 · 푸시 적체
#   ④ 업체 승인 대기열
#   ⑤ 지역 재인증 만료 임박 계정(30일 주기)
#   ⑥ 알림 unread 카운터 드리프트(하드삭제 트리거 공백 보정 대상)
#   ⑦ 주간 지표(가입·게시글·댓글)
#   ⑧ DB·스토리지 용량
#   ⑨ 백업 최신성(7일 초과 시 경고)
#   ⑩ 테스트 프로젝트 일시정지 여부(무료 티어 1주 미사용 pause)
#   ⑪ 수동 확인 리마인더(Solapi 잔액 등 API 로 못 보는 것)
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"
. scripts/backup.env

q()  { psql "$SUPABASE_DB_URL" -X -t -A -F' | ' -c "$1"; }
q1() { psql "$SUPABASE_DB_URL" -X -t -A -c "$1"; }

hr() { echo "────────────────────────────────────────────────"; }
echo "PawMate 주간 점검 — $(date '+%Y-%m-%d %H:%M')"
hr

# ① 미처리 신고 — 24시간 의무가 있으므로 최우선.
n=$(q1 "select count(*) from public.reports where reviewed_at is null")
if [ "$n" -gt 0 ]; then
  echo "⚠ ① 미처리 신고 ${n}건 — 관리자 화면에서 즉시 처리"
  q "select '   · '||target_type||' / '||array_to_string(categories,',')||' / '||to_char(created_at,'MM-DD HH24:MI') from public.reports where reviewed_at is null order by created_at limit 10"
else
  echo "✅ ① 신고: 미처리 없음"
fi

# ② 클라이언트 오류 — 최근 7일 상위 유형.
n=$(q1 "select count(*) from app.client_errors where created_at > now() - interval '7 days'")
if [ "$n" -gt 0 ]; then
  echo "⚠ ② 클라이언트 오류 최근 7일 ${n}건 — 상위 유형:"
  q "select '   · '||count(*)||'회  ['||coalesce(platform,'?')||'] '||where_key||' — '||left(message, 60) from app.client_errors where created_at > now() - interval '7 days' group by platform, where_key, left(message, 60) order by count(*) desc limit 5"
else
  echo "✅ ② 클라이언트 오류: 최근 7일 없음"
fi

# ③ 크론 실패 + 푸시 적체 — push-sweep 이 매분 도는데 pending 이 10분 넘게
#    남아 있으면 스위프가 죽었거나 send-push 가 실패 중이라는 뜻.
fails=$(q1 "select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '7 days'")
if [ "$fails" -gt 0 ]; then
  echo "⚠ ③ 크론 실패 최근 7일 ${fails}건:"
  q "select '   · '||coalesce(j.jobname, d.command)||' × '||count(*)||'회, 최근 '||to_char(max(d.start_time),'MM-DD HH24:MI')||' — '||left(max(d.return_message), 60) from cron.job_run_details d left join cron.job j on j.jobid = d.jobid where d.status = 'failed' and d.start_time > now() - interval '7 days' group by 1 order by 1"
else
  echo "✅ ③ 크론: 최근 7일 실패 없음"
fi
stuck=$(q1 "select count(*) from public.notifications where push_status = 'pending' and created_at < now() - interval '10 minutes'")
[ "$stuck" -gt 0 ] && echo "⚠ ③-1 푸시 적체 ${stuck}건(10분 초과 pending) — send-push 로그 확인" \
                   || echo "✅ ③-1 푸시 적체 없음"

# ④ 업체 승인 대기.
n=$(q1 "select count(*) from public.business_profiles where status not in ('approved','rejected')")
if [ "$n" -gt 0 ]; then
  echo "⚠ ④ 업체 승인 대기 ${n}건:"
  q "select '   · '||business_name||' ('||status||') 신청 '||to_char(created_at,'MM-DD') from public.business_profiles where status not in ('approved','rejected') order by created_at limit 10"
else
  echo "✅ ④ 업체 승인: 대기 없음"
fi

# ⑤ 지역 재인증 만료 임박(7일 이내) — 30일 주기(REVERIFY_DAYS 와 동기).
#    심사·시연 계정이 만료되면 해외 심사자는 재인증이 불가능하다.
rows=$(q "select '   · '||username||' — D-'||(30 - floor(extract(epoch from now() - last_verified_at) / 86400))::int from public.users where status = 'active' and is_location_verified and last_verified_at is not null and (30 - floor(extract(epoch from now() - last_verified_at) / 86400)) <= 7 order by last_verified_at")
if [ -n "$rows" ]; then
  echo "⚠ ⑤ 지역 재인증 만료 임박(7일 이내):"
  echo "$rows"
else
  echo "✅ ⑤ 지역 재인증: 임박 계정 없음"
fi

# ⑥ unread 알림 카운터 드리프트 — 하드삭제 경로에 DELETE 트리거가 없어 생길 수
#    있다. 발견 시 app.reconcile_unread_counts() 로 보정(스크립트는 실행 안 함).
n=$(q1 "select count(*) from public.users u where u.status = 'active' and u.unread_notification_count <> (select count(*) from public.notifications n where n.user_id = u.id and not n.is_read)")
[ "$n" -gt 0 ] && echo "⚠ ⑥ unread 카운터 드리프트 ${n}명 — psql 에서 select app.reconcile_unread_counts(); 실행" \
               || echo "✅ ⑥ unread 카운터: 드리프트 없음"

# ⑦ 주간 지표.
echo "ℹ ⑦ 최근 7일: 가입 $(q1 "select count(*) from public.users where created_at > now() - interval '7 days'")명 · 게시글 $(q1 "select count(*) from public.posts where created_at > now() - interval '7 days'")건 · 댓글 $(q1 "select count(*) from public.comments where created_at > now() - interval '7 days'")건 · 신고 $(q1 "select count(*) from public.reports where created_at > now() - interval '7 days'")건"

# ⑧ 용량.
echo "ℹ ⑧ DB $(q1 "select pg_size_pretty(pg_database_size(current_database()))") · 스토리지 $(q1 "select count(*)||'개 / '||pg_size_pretty(coalesce(sum((metadata->>'size')::bigint),0)) from storage.objects")"

# ⑨ 백업 최신성.
BDIR="${BACKUP_DIR:-backups}"
latest=$(ls -t "$BDIR" 2>/dev/null | head -1)
if [ -z "$latest" ]; then
  echo "⚠ ⑨ 백업 없음 — ./scripts/backup.sh 실행"
else
  age_days=$(( ($(date +%s) - $(stat -f %m "$BDIR/$latest")) / 86400 ))
  if [ "$age_days" -gt 7 ]; then
    echo "⚠ ⑨ 마지막 백업 ${age_days}일 전($latest) — ./scripts/backup.sh 실행"
  else
    echo "✅ ⑨ 백업: ${age_days}일 전($latest)"
  fi
fi

# ⑩ 테스트 프로젝트 pause 여부(무료 티어 1주 미사용 시 정지).
if command -v supabase >/dev/null 2>&1; then
  st=$(supabase projects list 2>/dev/null | python3 -c "import json,sys
try:
  for p in json.load(sys.stdin)['projects']:
    if p['name'] == 'PAWMATE-TEST': print(p['status']); break
except Exception: pass" 2>/dev/null)
  case "$st" in
    ACTIVE_HEALTHY) echo "✅ ⑩ 테스트 프로젝트: 활성" ;;
    "")             echo "ℹ ⑩ 테스트 프로젝트: 상태 확인 실패(CLI 로그인 확인)" ;;
    *)              echo "⚠ ⑩ 테스트 프로젝트: $st — 대시보드에서 재개(restore) 필요" ;;
  esac
else
  echo "ℹ ⑩ supabase CLI 없음 — 테스트 프로젝트 상태 생략"
fi

hr
echo "수동 확인 리마인더:"
echo "  · Solapi 잔액(console.solapi.com) — 떨어지면 OTP 가입이 통째로 막힌다"
echo "  · 스토어 리뷰·테스터 피드백 답변"
echo "  · TestFlight 빌드 만료(90일) — 마지막 업로드 2달 지났으면 새 빌드"
