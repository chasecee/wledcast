#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/logs/agent.json"
PERF="$ROOT/logs/perf.log"
LIB_AGENT="$HOME/Library/Logs/WledCast/agent.json"
LIB_PERF="$HOME/Library/Logs/WledCast/perf.log"

pick() {
  if [[ -f "$AGENT" ]]; then
    echo "$AGENT"
  elif [[ -f "$LIB_AGENT" ]]; then
    echo "$LIB_AGENT"
  else
    echo ""
  fi
}

AGENT_PATH="$(pick)"
PERF_PATH="$PERF"
if [[ ! -f "$PERF_PATH" && -f "$LIB_PERF" ]]; then
  PERF_PATH="$LIB_PERF"
fi

echo "=== wledcast perf snapshot ==="
echo "repo: $ROOT"
echo "agent: ${AGENT_PATH:-missing}"
echo "perf: ${PERF_PATH:-missing}"
echo

if [[ -n "$AGENT_PATH" ]]; then
  if command -v jq >/dev/null 2>&1; then
    jq '.' "$AGENT_PATH"
  else
    cat "$AGENT_PATH"
  fi
else
  echo '{"error":"no agent.json — stream not running or app not rebuilt"}'
fi

echo
echo "=== perf.log tail (last 15 lines) ==="
if [[ -f "$PERF_PATH" ]]; then
  tail -n 15 "$PERF_PATH"
else
  echo "(missing)"
fi
