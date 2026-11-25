#!/usr/bin/env bash
# Builds the app, quits the installed copy if it runs (sessions live on in tmux), installs it into
# ~/Applications and opens it. Its first launch turns Open at login on.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
TARGET="$HOME/Applications/Terminal Manager.app"
BINARY="$TARGET/Contents/MacOS/terminal-manager"

if pgrep -f -x "$BINARY" >/dev/null 2>&1; then
  osascript -e 'tell application id "com.brodykretz.terminal-manager" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 50); do pgrep -f -x "$BINARY" >/dev/null 2>&1 || break; sleep 0.1; done
  pkill -f -x "$BINARY" 2>/dev/null || true
fi

mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
cp -R "build/Terminal Manager.app" "$TARGET"
open "$TARGET"
echo "installed: $TARGET"
