#!/usr/bin/env bash
# serve.sh — bring up a model for benchmarking via the backend adapter.
#   scripts/serve.sh <runbook.sh>        # up (prints endpoint URL)
#   scripts/serve.sh down                # tear the server down
#
# Backend is vLLM for now; the adapter is the only backend-specific piece.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"

if [ "${1:-}" = "down" ]; then exec "$ADAPTER" down; fi

RUNBOOK="${1:?usage: serve.sh <runbook.sh> | serve.sh down}"
# Provide the current node profile to the adapter (single-node auto-detect).
NODE_PROFILE="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json 2>/dev/null | head -1 || true)"
exec "$ADAPTER" up "$RUNBOOK" "$NODE_PROFILE"
