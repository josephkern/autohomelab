#!/usr/bin/env bash
# eval_bfcl.sh <runbook.sh> [test_categories] — TOOL-CALLING gate (Berkeley Function-Calling Leaderboard
# V4) against the LIVE vLLM OpenAI endpoint. BFCL is NOT an lm-eval task, so this is a standalone runner
# (sibling to eval.sh) that wraps the official `bfcl` CLI and records one accuracy.tsv row (suite=tools).
#
# IMPORTANT (from the 2026-06 deep-research): BFCL's contamination-resistance is NOT established (two such
# claims were REFUTED in verification). Treat this as a CAPABILITY gate for tool/function calling, NOT a
# contamination-resistant gate. AST-based scoring; public leaderboard at gorilla.cs.berkeley.edu.
#
# PREREQUISITES (the runner does NOT serve the model — it hits an already-running endpoint):
#   1. The runbook must declare  BFCL_MODEL="<a handler name from `bfcl models`>"  e.g. "Qwen/Qwen3-8B-FC".
#      Only models BFCL ships a handler for can be scored (each handler knows that family's tool format).
#      Our Qwen3-8B final maps to Qwen/Qwen3-8B-FC; Nemotron-3-Super / gemma-4 / VibeThinker have NO exact
#      handler (skip, or add one upstream). "-FC" = native function-calling API; bare name = prompt mode.
#   2. SERVE that model with tools enabled AND --served-model-name MATCHING what the BFCL handler sends
#      (BFCL --skip-server-setup posts to the local endpoint using the handler's model string). Easiest:
#      serve with  --served-model-name "<BFCL_MODEL without the -FC suffix>"  (e.g. Qwen/Qwen3-8B) +
#      --enable-auto-tool-choice --tool-call-parser <family parser>.
#
# Usage:  scripts/serve.sh <runbook>   # tools-enabled, served-name matched   (then:)
#         scripts/eval_bfcl.sh <runbook> [simple_python,multiple,parallel,irrelevance,live_simple,live_multiple]
# Env: AHL_HOST/AHL_PORT (endpoint, default 127.0.0.1:8000), TEMP (default 0), BFCL_VER (pin), CATS override.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNBOOK="${1:?usage: eval_bfcl.sh <runbook.sh> [test_categories]}"
[ -f "$RUNBOOK" ] || { echo "not found: $RUNBOOK" >&2; exit 1; }

MODEL=""; SERVED_NAME=""; BFCL_MODEL=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
if [ -z "${BFCL_MODEL:-}" ]; then
  echo "SKIP: $RUNBOOK does not set BFCL_MODEL — no BFCL handler for this model. (see \`bfcl models\`)" >&2
  exit 3
fi

: "${AHL_HOST:=127.0.0.1}"; : "${AHL_PORT:=8000}"
TEMP="${TEMP:-0}"
# Default category mix: a quick functional spread + the 'live' (real-world-sourced) ones. Override with $2/$CATS.
CATS="${2:-${CATS:-simple_python,multiple,parallel,irrelevance,live_simple,live_multiple,live_irrelevance}}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-bfcl"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
TSV="$OUT_DIR/accuracy.tsv"
# BFCL writes result/ and score/ under BFCL_PROJECT_ROOT; point it at our bundle so artifacts are captured.
export BFCL_PROJECT_ROOT="$BUNDLE"
export LOCAL_SERVER_ENDPOINT="$AHL_HOST" LOCAL_SERVER_PORT="$AHL_PORT"
# bfcl-eval has a packaging gap (qwen_agent -> soundfile); --with soundfile fixes it. Isolated via uvx.
BFCL=(uvx --from "bfcl-eval${BFCL_VER:+==$BFCL_VER}" --with soundfile bfcl)

echo "== BFCL tool-calling: $BFCL_MODEL on $CATS @ http://$AHL_HOST:$AHL_PORT (served=$SERVED_NAME) ==" >&2
"${BFCL[@]}" generate --model "$BFCL_MODEL" --backend vllm --skip-server-setup \
  --test-category "$CATS" --temperature "$TEMP" >"$BUNDLE/generate.log" 2>&1 \
  || { echo "bfcl generate failed — see $BUNDLE/generate.log" >&2; tail -5 "$BUNDLE/generate.log" >&2; exit 1; }
"${BFCL[@]}" evaluate --model "$BFCL_MODEL" --test-category "$CATS" >"$BUNDLE/evaluate.log" 2>&1 \
  || { echo "bfcl evaluate failed — see $BUNDLE/evaluate.log" >&2; tail -5 "$BUNDLE/evaluate.log" >&2; exit 1; }

# Parse overall accuracy. BFCL writes a score CSV (data_overall.csv) under $BFCL_PROJECT_ROOT/score/.
# (Best-effort — VALIDATE the column/path on the first real run and tighten this.)
SCOREFILE="$(find "$BUNDLE" -name 'data_overall.csv' -o -name '*overall*.csv' 2>/dev/null | head -1)"
OVERALL="$(python3 - "$SCOREFILE" 2>/dev/null <<'PY'
import sys,csv,os
p=sys.argv[1]
if not p or not os.path.exists(p): print("na"); sys.exit()
rows=list(csv.reader(open(p)))
# find a header col mentioning accuracy/overall and the first data row's value
hdr=[c.lower() for c in rows[0]] if rows else []
import re
idx=next((i for i,c in enumerate(hdr) if 'overall' in c and 'acc' in c), next((i for i,c in enumerate(hdr) if 'accuracy' in c), None))
val="na"
if idx is not None and len(rows)>1: val=rows[1][idx]
print(val)
PY
)"
SCORES="bfcl_overall=${OVERALL:-na}"
echo "scores: $SCORES" >&2

# accuracy.tsv is 16 columns since docs/validity-contract.md A9. This harness is not lm-eval and
# emits no `n-samples` bundle, so the Gate-2 predicate cannot be evaluated for its row: `samples`,
# `validity` and `status` are recorded as `na`, which contract A5 says is NEVER `ok` -- an
# unevaluable quality number is reported as unevaluable, not asserted clean. A legacy 12-column
# journal is migrated in place first, so this append can never widen a narrow file.
migrate_acc(){ [ -f "$1" ] && [ "$(head -1 "$1")" != "$2" ] && \
  python3 "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$1" --bundle-root "$REPO_ROOT" --write >&2
  return 0; }
# accuracy.tsv header comes from scripts/eval_validity.py — one definition, five
# callers. Five hard-coded copies is the exact defect issue #1 opened on.
HDR="$(uv run --project "$REPO_ROOT" python "$SCRIPT_DIR/eval_validity.py" accuracy-header \
        2>/dev/null || python3 "$SCRIPT_DIR/eval_validity.py" accuracy-header)"
migrate_acc "$TSV" "$HDR"
[ -f "$TSV" ] || printf '%s\n' "$HDR" > "$TSV"
DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" \
  "tools" "$CATS" "full" "$SCORES" "$DATA_REL" "na" "${CONC:-na}" "na" "na" "na" >> "$TSV"
echo "row -> $TSV" >&2
