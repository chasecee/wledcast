#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$ROOT_DIR/dist/WledCast.app"
BIN_PATTERN="WledCast.app/Contents/MacOS/wledcast-swift"

if osascript -e 'tell application id "io.wledcast.native" to quit' >/dev/null 2>&1; then
  for _ in {1..40}; do
    if ! pgrep -f "$BIN_PATTERN" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi

if pgrep -f "$BIN_PATTERN" >/dev/null 2>&1; then
  pkill -TERM -f "$BIN_PATTERN" || true
  sleep 0.3
fi

"$ROOT_DIR/Scripts/package_macos_app.sh"
open "$APP_PATH"
