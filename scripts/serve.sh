#!/usr/bin/env bash
# serve.sh — bring up a model for benchmarking via the backend adapter, timing time-to-healthy.
#   scripts/serve.sh <runbook.sh>        # up (prints endpoint URL; records load seconds)
#   scripts/serve.sh down                # tear the server down
#
# Records the load tax (container start -> /v1/models healthy) to .ahl_serve_state so the loop and
# bench.sh can budget around it — load/unload is the fixed per-experiment cost on restart-required
# config changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"
STATE="$REPO_ROOT/.ahl_serve_state"

if [ "${1:-}" = "down" ]; then rm -f "$STATE"; exec "$ADAPTER" down; fi

RUNBOOK="${1:?usage: serve.sh <runbook.sh> | serve.sh down}"
NODE_PROFILE="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json 2>/dev/null | head -1 || true)"

start=$(date +%s)
URL="$("$ADAPTER" up "$RUNBOOK" "$NODE_PROFILE")"   # progress -> stderr, URL -> stdout
LOAD_S=$(( $(date +%s) - start ))

{ echo "RUNBOOK_SERVED=$(realpath "$RUNBOOK")"
  echo "LOAD_S=$LOAD_S"
  echo "SERVED_AT=$(date -u +%FT%TZ)"; } > "$STATE"

echo "ready in ${LOAD_S}s -> $URL" >&2
echo "$URL"
