#!/usr/bin/env bash
#
# Start/stop the local wifi-csi-pose UI stack.
#
#   ./scripts/stack.sh start|stop|status|restart
#
# Two processes:
#   :8765  run-sim-sensing.py  -- sensing server, SimulatedCollector forced
#   :8000  run-ui-stack.py     -- FastAPI + /ws/sensing relay + static ui/
#
# The UI resolves its backend from window.location.origin, so everything must
# be same-origin -- open http://localhost:8000/index.html, not :3000.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$REPO_ROOT/.venvs/api312/bin/python"
SENSE_PY="$REPO_ROOT/.venvs/proof312/bin/python"
RUN="$REPO_ROOT/.run"
LOGS="$REPO_ROOT/logs"
URL="http://localhost:8000/index.html"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi

mkdir -p "$RUN" "$LOGS"

_pid_of_port() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }

_wait_port() { # _wait_port <port> <seconds>
  local p="$1" n="$2" i=0
  while [ "$i" -lt "$n" ]; do
    [ -n "$(_pid_of_port "$p")" ] && return 0
    i=$((i+1)); /bin/sleep 1
  done
  return 1
}

start() {
  for f in "$PY" "$SENSE_PY"; do
    if [ ! -x "$f" ]; then
      printf '%sMissing venv:%s %s\n' "$R" "$N" "$f" >&2
      printf 'Recreate with scripts/test-submodule.sh tier1b, then reinstall API deps.\n' >&2
      exit 1
    fi
  done

  if [ -n "$(_pid_of_port 8765)" ]; then
    printf '  %s..%s :8765 already running (pid %s)\n' "$Y" "$N" "$(_pid_of_port 8765)"
  else
    nohup "$SENSE_PY" "$REPO_ROOT/scripts/run-sim-sensing.py" \
      >"$LOGS/sensing.log" 2>&1 &
    echo $! >"$RUN/sensing.pid"
    _wait_port 8765 20 || { printf '%sFAIL%s :8765 did not come up; see %s\n' "$R" "$N" "$LOGS/sensing.log"; exit 1; }
    printf '  %sok%s   :8765 sensing (SimulatedCollector)\n' "$G" "$N"
  fi

  if [ -n "$(_pid_of_port 8000)" ]; then
    printf '  %s..%s :8000 already running (pid %s)\n' "$Y" "$N" "$(_pid_of_port 8000)"
  else
    nohup "$PY" "$REPO_ROOT/scripts/run-ui-stack.py" \
      >"$LOGS/ui-stack.log" 2>&1 &
    echo $! >"$RUN/ui-stack.pid"
    # torch import makes first start slow
    _wait_port 8000 90 || { printf '%sFAIL%s :8000 did not come up; see %s\n' "$R" "$N" "$LOGS/ui-stack.log"; exit 1; }
    printf '  %sok%s   :8000 api + ui\n' "$G" "$N"
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)
  if [ "$code" = "200" ]; then
    printf '\n  %sopen:%s %s\n' "$B" "$N" "$URL"
  else
    printf '\n  %swarn%s UI returned HTTP %s; see %s\n' "$Y" "$N" "$code" "$LOGS/ui-stack.log"
  fi
}

stop() {
  local p pid
  for p in 8000 8765; do
    pid="$(_pid_of_port "$p")"
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; printf '  stopped :%s (pid %s)\n' "$p" "$pid"
    else printf '  :%s not running\n' "$p"; fi
  done
  rm -f "$RUN"/*.pid
}

status() {
  local p pid
  for p in 8000 8765; do
    pid="$(_pid_of_port "$p")"
    if [ -n "$pid" ]; then printf '  %sup%s   :%-5s pid %s\n' "$G" "$N" "$p" "$pid"
    else printf '  %sdown%s :%s\n' "$R" "$N" "$p"; fi
  done
  [ -n "$(_pid_of_port 8000)" ] && printf '  url: %s\n' "$URL"
  return 0
}

case "${1:-status}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; /bin/sleep 1; start ;;
  status)  status ;;
  *) printf 'usage: %s start|stop|status|restart\n' "$0" >&2; exit 2 ;;
esac
