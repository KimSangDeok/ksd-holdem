#!/usr/bin/env bash
# 배포 서버의 로그를 읽는다 (game-log.txt = 게임·코치 타임라인, coach-log.txt = 코치 호출별 시간·사용량).
# 서버는 개인 키로 서명한 요청만 받아 준다 (coach-server.ps1 의 /logs).
# 필요한 환경 변수 — 둘 다 Claude 작업 환경 설정에만 둔다. 저장소에 넣지 말 것 (규칙 9):
#   HOLDEM_SERVER   서버 주소 (예: http://<주소>:8765)
#   HOLDEM_LOG_KEY  개인 키 (PKCS#8 DER 을 base64 한 줄)
# 사용: ./read-logs.sh [game|coach] [끝에서 몇 줄, 기본 300]
{ set +x; } 2>/dev/null   # 키를 다루므로 추적 출력(bash -x)에 찍히지 않게
set -euo pipefail
file="${1:-game}"; tail="${2:-300}"
: "${HOLDEM_SERVER:?HOLDEM_SERVER 환경 변수가 없습니다}"
: "${HOLDEM_LOG_KEY:?HOLDEM_LOG_KEY 환경 변수가 없습니다}"
t=$(date +%s%3N)
sig=$(printf '%s' "logs|$file|$tail|$t" \
  | openssl dgst -sha256 -keyform DER -sign <(printf '%s' "$HOLDEM_LOG_KEY" | base64 -d) \
  | base64 -w0 | tr '+/' '-_' | tr -d '=')
proxy=()
# Claude 클라우드 세션은 바깥 연결이 프록시 터널로만 나간다 (일반 http 요청은 405)
if [ -n "${HTTPS_PROXY:-}" ]; then proxy=(-p -x "$HTTPS_PROXY"); fi
# 서명이 든 주소는 프로세스 목록(argv)에 남지 않게 표준 입력 설정(-K -)으로 넘기고, 키는 curl에 넘기지 않는다
printf 'url = "%s"\n' "$HOLDEM_SERVER/logs?file=$file&tail=$tail&t=$t&sig=$sig" \
  | env -u HOLDEM_LOG_KEY curl -sS -m 30 "${proxy[@]}" --fail-with-body -K -
echo
