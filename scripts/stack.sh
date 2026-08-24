#!/usr/bin/env bash
#
# Start/stop the local wifi-csi-pose stack.
#
#   ./scripts/stack.sh start|stop|status|restart|build
#
# One process: the Rust sensing-server. It serves the static UI, the REST API,
# and the /ws/sensing WebSocket from the SAME origin, which is what the UI
# needs -- ui/config/api.config.js derives its backend from
# window.location.origin and ui/services/sensing.service.js derives its socket
# as ${origin}/ws/sensing.
#
# This replaces the earlier two-process Python stack (run-ui-stack.py +
# run-sim-sensing.py), which existed only to work around the Python API not
# serving the UI or /ws/sensing. It also drops the torch/FastAPI dependency.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$REPO_ROOT/external/wifi-csi-pose"
WS="$SUB/rust-port/wifi-densepose-rs"
CARGO="$HOME/.cargo/bin/cargo"
TARGET="$REPO_ROOT/.cargo-target"
BIN="$TARGET/release/sensing-server"
LOGS="$REPO_ROOT/logs"

HTTP_PORT=8000
WS_PORT=8765
TICK_MS=200
URL="http://localhost:${HTTP_PORT}/ui/index.html"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi

mkdir -p "$LOGS"

_pid_of_port() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }

build() {
  if [ ! -x "$CARGO" ]; then
    printf '%sNo cargo.%s Install with:\n' "$R" "$N" >&2
    printf "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \\\\\n" >&2
    printf '    | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path\n' >&2
    exit 1
  fi
  printf '  building sensing-server (release)...\n'
  ( cd "$WS" && CARGO_TARGET_DIR="$TARGET" "$CARGO" build --release --locked \
      -p wifi-densepose-sensing-server ) >"$LOGS/rust-build.log" 2>&1 \
    || { printf '%sbuild failed%s -- see %s\n' "$R" "$N" "$LOGS/rust-build.log"; exit 1; }
  printf '  %sok%s   %s\n' "$G" "$N" "$BIN"
}

start() {
  [ -x "$BIN" ] || build

  if [ -n "$(_pid_of_port $HTTP_PORT)" ]; then
    printf '  %s..%s :%s already running (pid %s)\n' "$Y" "$N" "$HTTP_PORT" "$(_pid_of_port $HTTP_PORT)"
  else
    # cd into the submodule: --ui-path is resolved relative to cwd
    ( cd "$SUB" && nohup "$BIN" \
        --source simulate \
        --ui-path ./ui \
        --http-port "$HTTP_PORT" \
        --ws-port "$WS_PORT" \
        --tick-ms "$TICK_MS" >"$LOGS/sensing-server.log" 2>&1 & )
    local i=0
    while [ "$i" -lt 30 ]; do
      [ -n "$(_pid_of_port $HTTP_PORT)" ] && break
      i=$((i+1)); /bin/sleep 1
    done
    [ -n "$(_pid_of_port $HTTP_PORT)" ] || {
      printf '%sFAIL%s :%s did not come up; see %s\n' "$R" "$N" "$HTTP_PORT" "$LOGS/sensing-server.log"
      exit 1
    }
    printf '  %sok%s   :%s http+ui, :%s ws  (source=simulate)\n' "$G" "$N" "$HTTP_PORT" "$WS_PORT"
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)
  if [ "$code" = "200" ]; then
    printf '\n  %sopen:%s %s\n' "$B" "$N" "$URL"
  else
    printf '\n  %swarn%s UI returned HTTP %s; see %s\n' "$Y" "$N" "$code" "$LOGS/sensing-server.log"
  fi
}

stop() {
  local p pid
  for p in "$HTTP_PORT" "$WS_PORT"; do
    pid="$(_pid_of_port "$p")"
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; printf '  stopped :%s (pid %s)\n' "$p" "$pid"
    else printf '  :%s not running\n' "$p"; fi
  done
}

status() {
  local p pid
  for p in "$HTTP_PORT" "$WS_PORT"; do
    pid="$(_pid_of_port "$p")"
    if [ -n "$pid" ]; then printf '  %sup%s   :%-5s pid %s\n' "$G" "$N" "$p" "$pid"
    else printf '  %sdown%s :%s\n' "$R" "$N" "$p"; fi
  done
  [ -n "$(_pid_of_port $HTTP_PORT)" ] && printf '  url: %s\n' "$URL"
  return 0
}

case "${1:-status}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; /bin/sleep 1; start ;;
  build)   build ;;
  status)  status ;;
  *) printf 'usage: %s start|stop|status|restart|build\n' "$0" >&2; exit 2 ;;
esac
