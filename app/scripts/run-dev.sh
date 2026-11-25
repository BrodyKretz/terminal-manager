#!/usr/bin/env bash
# Debug build, run from a copy (later builds never overwrite the running binary) against app/web, so page
# changes need only a reload. Extra arguments go to the app, for example a scratch run:
#   scripts/run-dev.sh --support-dir /tmp/tm-scratch --tmux-socket tm-scratch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
swift build -c release --product terminal-manager-hook
mkdir -p build/dev
cp "$(swift build --show-bin-path)/terminal-manager" build/dev/terminal-manager
# The helper runs inside every Claude session: always the release build.
cp "$(swift build -c release --show-bin-path)/terminal-manager-hook" build/dev/terminal-manager-hook

PID_FILE=build/dev.pid
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE")"
  if [ -n "$OLD_PID" ] && [ "$(basename "$(ps -p "$OLD_PID" -o comm= 2>/dev/null || true)")" = "terminal-manager" ]; then
    kill -TERM "$OLD_PID" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.1; done
  fi
fi

nohup build/dev/terminal-manager --web-dir "$(pwd)/web" "$@" > build/dev.log 2>&1 &
NEW_PID=$!
sleep 0.5
kill -0 "$NEW_PID" 2>/dev/null || { echo "run-dev.sh: the app exited right away:" >&2; cat build/dev.log >&2; exit 1; }
echo "$NEW_PID" > "$PID_FILE"
echo "$NEW_PID"
