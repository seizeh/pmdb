#!/usr/bin/env bash
# ============================================================================
# PawMate 백업 더블클릭 실행기 (macOS 전용)
#   파인더에서 이 파일을 더블클릭하면 터미널이 열려 backup.sh 를 실행한다.
#   최초 1회: 같은 폴더의 backup.env.example 을 복사해 backup.env 로 만들고
#             연결문자열·패스프레이즈를 채운다. (backup.env 는 .gitignore 로 제외됨)
#
#   ※ 최초 더블클릭 시 macOS 가 실행을 막으면:
#      - 파일 우클릭 → "열기" 로 한 번 허용, 또는
#      - 터미널에서  chmod +x backup.command  실행
# ============================================================================
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# pg_dump(libpq) PATH 보강 — brew keg-only 라 자동 등록이 안 됨(Apple/Intel 경로 모두 시도)
export PATH="/opt/homebrew/opt/libpq/bin:/usr/local/opt/libpq/bin:$PATH"

# 설정 로드 (KEY=VALUE 를 export)
if [ -f "$DIR/backup.env" ]; then
  set -a; . "$DIR/backup.env"; set +a
else
  echo "⚠ 설정 파일이 없습니다: $DIR/backup.env"
  echo "  → backup.env.example 을 복사해 backup.env 로 만들고 값을 채우세요:"
  echo "     cp backup.env.example backup.env"
  echo
  read -n1 -r -p "창을 닫으려면 아무 키나 누르세요..."; echo
  exit 1
fi

# 실행 (실패해도 창은 열어둬 결과를 확인)
if bash "$DIR/backup.sh"; then
  echo
  echo "✅ 백업 완료."
else
  echo
  echo "❌ 백업 실패 — 위 오류 메시지를 확인하세요."
fi
echo
read -n1 -r -p "창을 닫으려면 아무 키나 누르세요..."; echo
