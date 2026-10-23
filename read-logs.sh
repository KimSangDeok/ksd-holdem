#!/usr/bin/env bash
# 예전 이름 그대로 쓰는 로그 읽기 — server.sh logs 와 같다. 사용: ./read-logs.sh [game|coach] [끝에서 몇 줄]
exec "$(dirname "$0")/server.sh" logs "$@"
