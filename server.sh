#!/usr/bin/env bash
# 배포 서버 읽기 전용 창구 (서명된 요청만 서버가 받아 준다 — coach-server.ps1 의 /logs·/status·/dbread)
# 필요한 환경 변수 — 둘 다 Claude 작업 환경 설정에만 둔다. 저장소에 넣지 말 것 (규칙 9):
#   HOLDEM_SERVER   서버 주소 (예: http://<주소>:8765)
#   HOLDEM_LOG_KEY  개인 키 (PKCS#8 DER 을 base64 한 줄)
# 사용:
#   ./server.sh logs [game|coach] [끝에서 몇 줄, 기본 300]   게임 타임라인 / 코치 호출 기록
#   ./server.sh status                                         켜진 시간, 돌고 있는 버전, 최근 서버 오류
#   ./server.sh db get <ns> <key>                              기록 서버 값 (예: db get holdem settings)
#   ./server.sh db log <ns> <log> [개수, 기본 20]              기록 서버 목록 끝부분 (예: db log holdem hands 10)
{ set +x; } 2>/dev/null   # 키를 다루므로 추적 출력(bash -x)에 찍히지 않게
set -euo pipefail
: "${HOLDEM_SERVER:?HOLDEM_SERVER 환경 변수가 없습니다}"
: "${HOLDEM_LOG_KEY:?HOLDEM_LOG_KEY 환경 변수가 없습니다}"
t=$(date +%s%3N)
cmd="${1:-}"; shift || true
bad() { echo "잘못된 값: $1" >&2; exit 2; }
id_ok() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }   # 서버 검사와 같은 규칙. 따옴표·줄바꿈이 curl 설정(-K -)에 끼어들지 못하게
num_ok() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]]; }
case "$cmd" in
  logs)   file="${1:-game}"; tail="${2:-300}"
          [[ "$file" == game || "$file" == coach ]] || bad "$file"; num_ok "$tail" || bad "$tail"
          msg="logs|$file|$tail|$t";            q="file=$file&tail=$tail";               path=logs ;;
  status) msg="status|$t";                      q="";                                    path=status ;;
  db)     kind="${1:-}"; ns="${2:-}"; name="${3:-}"
          [[ "$kind" == get || "$kind" == log ]] || bad "$kind"; id_ok "$ns" || bad "$ns"; id_ok "$name" || bad "$name"
          if [ "$kind" = log ]; then tail="${4:-20}"; num_ok "$tail" || bad "$tail"; else tail=""; fi
          msg="dbread|$kind|$ns|$name|$tail|$t"; q="kind=$kind&ns=$ns&name=$name&tail=$tail"; path=dbread ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
sig=$(printf '%s' "$msg" \
  | openssl dgst -sha256 -keyform DER -sign <(printf '%s' "$HOLDEM_LOG_KEY" | base64 -d) \
  | base64 -w0 | tr '+/' '-_' | tr -d '=')
proxy=()
# Claude 클라우드 세션은 바깥 연결이 프록시 터널로만 나간다 (일반 http 요청은 405)
if [ -n "${HTTPS_PROXY:-}" ]; then proxy=(-p -x "$HTTPS_PROXY"); fi
# 서명이 든 주소는 프로세스 목록(argv)에 남지 않게 표준 입력 설정(-K -)으로 넘기고, 키는 curl에 넘기지 않는다
printf 'url = "%s"\n' "$HOLDEM_SERVER/$path?${q:+$q&}t=$t&sig=$sig" \
  | env -u HOLDEM_LOG_KEY curl -sS -m 30 "${proxy[@]}" --fail-with-body -K -
echo
