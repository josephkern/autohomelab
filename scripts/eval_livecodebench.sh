#!/usr/bin/env bash
# eval_livecodebench.sh <runbook.sh> <model_cutoff_YYYY-MM-DD> [scenario] — CODING gate (LiveCodeBench)
# against the LIVE vLLM OpenAI endpoint. Not an lm-eval task -> standalone runner (sibling to eval.sh).
# One accuracy.tsv row (suite=coding_lcb). Scoring = unit-tests/pass@1 -> RUNS GENERATED CODE LOCALLY
# (sandbox-ish via ProcessPoolExecutor) — only run on a node you trust.
#
# CONTAMINATION MECHANISM: date-gating. Every problem is annotated with its contest release date; pass the
# MODEL'S TRAINING CUTOFF as <model_cutoff> so scoring counts ONLY post-cutoff problems (the lever is at the
# compute_scores step, --start_date). DeepSeek models show a stark perf drop on post-cutoff LeetCode —
# i.e. the date-window empirically detects train/test overlap. Always pull the newest release. [deep-research 2026-06]
#
# ONE-TIME SETUP (repo install + model registry edit):
#   git clone https://github.com/LiveCodeBench/LiveCodeBench  source/LiveCodeBench   # gitignored
#   (cd source/LiveCodeBench && uv venv && uv pip install -e .)
#   Register the served model: add a LanguageModel(...) entry to lcb_runner/lm_styles.py with
#     model_name == your SERVED_NAME and LMStyle.OpenAIChat (so the oai_runner + OPENAI_BASE_URL is used).
#   Runbook should set LCB_MODEL="<that registered name>" (defaults to SERVED_NAME). Override repo via LCB_REPO.
#
# Usage: scripts/serve.sh <runbook>  (then:)  scripts/eval_livecodebench.sh <runbook> 2024-09-01 [codegeneration]
# Env: AHL_HOST/AHL_PORT (default 127.0.0.1:8000), LCB_REPO, RELEASE_VER (default release_latest),
#      N (default 1), TEMP (default 0.2), LCB_MODEL (override served name).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNBOOK="${1:?usage: eval_livecodebench.sh <runbook.sh> <model_cutoff_YYYY-MM-DD> [scenario]}"
CUTOFF="${2:?need the model training cutoff date YYYY-MM-DD = start of the post-cutoff contamination window}"
[ -f "$RUNBOOK" ] || { echo "not found: $RUNBOOK" >&2; exit 1; }
LCB_REPO="${LCB_REPO:-$REPO_ROOT/source/LiveCodeBench}"
[ -d "$LCB_REPO" ] || { echo "LiveCodeBench repo not found at $LCB_REPO — see ONE-TIME SETUP in the header above." >&2; exit 2; }

MODEL=""; SERVED_NAME=""; LCB_MODEL=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
LCBM="${LCB_MODEL:-$SERVED_NAME}"
: "${AHL_HOST:=127.0.0.1}"; : "${AHL_PORT:=8000}"
SCENARIO="${3:-codegeneration}"; RELEASE_VER="${RELEASE_VER:-release_latest}"; N="${N:-1}"; TEMP="${TEMP:-0.2}"

ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-lcb"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"; SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
TSV="$OUT_DIR/accuracy.tsv"
# LCB's oai_runner uses the OpenAI SDK; OPENAI_BASE_URL + OPENAI_KEY point it at the local vLLM endpoint.
export OPENAI_BASE_URL="http://$AHL_HOST:$AHL_PORT/v1" OPENAI_KEY="${OPENAI_KEY:-none}" OPENAI_API_KEY="${OPENAI_API_KEY:-none}"

echo "== LiveCodeBench: $LCBM $SCENARIO ($RELEASE_VER) post-cutoff>=$CUTOFF @ $OPENAI_BASE_URL ==" >&2
( cd "$LCB_REPO" && uv run python -m lcb_runner.runner.main \
    --model "$LCBM" --scenario "$SCENARIO" --release_version "$RELEASE_VER" \
    --n "$N" --temperature "$TEMP" --evaluate ) >"$BUNDLE/run.log" 2>&1 \
  || { echo "lcb run failed — see $BUNDLE/run.log" >&2; tail -8 "$BUNDLE/run.log" >&2; exit 1; }

# Date-windowed re-score: count ONLY problems released after the model's cutoff (contamination control).
EVAL_FILE="$(find "$LCB_REPO" -path '*output*' -name '*_eval_all.json' -newer "$BUNDLE/run.log" 2>/dev/null | head -1)"
( cd "$LCB_REPO" && uv run python -m lcb_runner.evaluation.compute_scores \
    ${EVAL_FILE:+--eval_all_file "$EVAL_FILE"} --start_date "$CUTOFF" ) >"$BUNDLE/scores_postcutoff.log" 2>&1 || true
cp -f "${EVAL_FILE:-/dev/null}" "$BUNDLE/" 2>/dev/null || true

# pass@1 over the post-cutoff window (best-effort parse — VALIDATE + tighten on first real run).
P1="$(grep -aoiE 'pass@1[^0-9]*([0-9]+\.[0-9]+)' "$BUNDLE/scores_postcutoff.log" "$BUNDLE/run.log" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | tail -1)"
SCORES="lcb_${SCENARIO}_pass@1_postcutoff=${P1:-na}"
echo "scores: $SCORES (window >= $CUTOFF)" >&2

# accuracy.tsv is 16 columns since docs/validity-contract.md A9. This harness is not lm-eval and
# emits no `n-samples` bundle, so the Gate-2 predicate cannot be evaluated for its row: `samples`,
# `validity` and `status` are recorded as `na`, which contract A5 says is NEVER `ok` -- an
# unevaluable quality number is reported as unevaluable, not asserted clean. A legacy 12-column
# journal is migrated in place first, so this append can never widen a narrow file.
migrate_acc(){ [ -f "$1" ] && [ "$(head -1 "$1")" != "$2" ] && \
  python3 "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$1" --bundle-root "$REPO_ROOT" --write >&2
  return 0; }
HDR=$'run_id\tcommit\tnode_fp\tmodel\tconfig_hash\tscript\tsuite\ttasks\tlimit\tscores\tdata\tthink\tconc\tsamples\tvalidity\tstatus'
migrate_acc "$TSV" "$HDR"
[ -f "$TSV" ] || printf '%s\n' "$HDR" > "$TSV"
DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" \
  "coding_lcb" "$SCENARIO@$RELEASE_VER>=$CUTOFF" "full" "$SCORES" "$DATA_REL" "na" "${CONC:-na}" "na" "na" "na" >> "$TSV"
echo "row -> $TSV" >&2
