#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v fswatch >/dev/null; then
    echo "fswatch not found. Install with: brew install fswatch"
    exit 1
fi

PID=""

stop_app() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}

start_app() {
    echo "[dev_watch] swift run wledcast-swift"
    swift run wledcast-swift &
    PID=$!
    echo "[dev_watch] launched pid=$PID"
}

trap 'stop_app; exit 0' INT TERM EXIT

start_app

fswatch \
    --recursive \
    --latency 0.4 \
    --event Updated --event Created --event Removed --event Renamed \
    --exclude ".*" \
    --include "\\.swift$" \
    "$ROOT_DIR/Sources" "$ROOT_DIR/Tests" "$ROOT_DIR/Package.swift" \
| while read -r _; do
    echo "[dev_watch] change detected, restarting"
    stop_app
    start_app
done
