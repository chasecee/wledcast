#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/.build/debug/wledcast-ctl"
AGENT="$ROOT/logs/agent.json"
REPORT="$ROOT/logs/profile_report.json"
PID_PATTERN="WledCast.app/Contents/MacOS/wledcast-swift"
WINDOW_SEC="${WINDOW_SEC:-4}"

sample_cpu() {
  local pid
  pid="$(pgrep -f "$PID_PATTERN" | head -1 || true)"
  if [[ -z "$pid" ]]; then
    echo "0"
    return
  fi
  ps -p "$pid" -o pcpu= 2>/dev/null | tr -d ' ' || echo "0"
}

read_step() {
  local name="$1"
  local cpu tmp
  cpu="$(sample_cpu)"
  [[ "$cpu" =~ ^[0-9.]+$ ]] || cpu="0"
  tmp="$(mktemp)"
  if [[ -f "$AGENT" ]]; then cp "$AGENT" "$tmp"; else echo '{"hint":"no agent.json"}' > "$tmp"; fi
  jq empty "$tmp" 2>/dev/null || echo '{"hint":"invalid agent.json"}' > "$tmp"
  jq -nc --arg name "$name" --argjson cpu "$cpu" --slurpfile snap "$tmp" \
    '{name:$name, cpu:$cpu, snapshot:$snap[0]}'
  rm -f "$tmp"
}

ctl() {
  [[ -x "$CTL" ]] || return 1
  "$CTL" "$@" 2>/dev/null
}

sleep "$WINDOW_SEC"
baseline="$(read_step baseline)"

if ctl status | grep -q '"ok":true'; then
  ctl overlay hide
  sleep "$WINDOW_SEC"
  hidden="$(read_step overlay_hidden)"
  ctl overlay show
else
  sleep "$WINDOW_SEC"
  hidden="$(read_step no_control)"
fi

mkdir -p "$ROOT/logs"
jq -nc \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson window_sec "$WINDOW_SEC" \
  --argjson baseline "$baseline" \
  --argjson hidden "$hidden" \
  '{generated_at:$generated_at, window_sec:$window_sec, scenarios:[$baseline,$hidden]}' \
  > "$REPORT"

echo "profile report: $REPORT"
jq '[.scenarios[] | {
  name,
  cpu,
  hint: .snapshot.hint,
  process_avg_ms: .snapshot.latestWindow.processAvgMs,
  hud: .snapshot.latestWindow.hudPreviewFrames,
  overlay: .snapshot.session.overlayVisible
}]' "$REPORT"
