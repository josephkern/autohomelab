#!/usr/bin/env bash
# eval_livebench.sh <runbook.sh> [bench_name] — GENERAL/REASONING gate (LiveBench) against the LIVE vLLM
# OpenAI endpoint. LiveBench is NOT an lm-eval task -> standalone runner (sibling to eval.sh). One
# accuracy.tsv row (suite=general_lb). Objective ground-truth grading, NO LLM judge.
#
# CONTAMINATION MECHANISM: time-gating — LiveBench releases new questions from sources postdating model
# cutoffs. RESISTANCE ONLY HOLDS for the newest release relative to a model's cutoff; older pools decay.
# As of 2026-06 the public refresh cadence had LAPSED (~2025-04), so ALWAYS pull the newest release and
# pick --livebench-release-option accordingly (see REFRESH below). [deep-research 2026-06]
#
# ONE-TIME SETUP (LiveBench isn't on PyPI — it's a repo install):
#   git clone https://github.com/LiveBench/LiveBench  source/LiveBench   # gitignored
#   (cd source/LiveBench && uv venv && uv pip install -e .)              # heavy deps
#   Override path with LIVEBENCH_REPO=...; the model is addressed by --api-base (no per-provider config needed).
#
# Usage:  scripts/serve.sh <runbook>   (then:)   scripts/eval_livebench.sh <runbook> [live_bench/reasoning]
# Env: AHL_HOST/AHL_PORT (default 127.0.0.1:8000), LIVEBENCH_REPO, RELEASE (--livebench-release-option),
#      MAX_TOKENS (default 32768 for long-CoT), PARALLEL (--parallel-requests, default 16), BENCH (override $2).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNBOOK="${1:?usage: eval_livebench.sh <runbook.sh> [bench_name]}"
[ -f "$RUNBOOK" ] || { echo "not found: $RUNBOOK" >&2; exit 1; }
LIVEBENCH_REPO="${LIVEBENCH_REPO:-$REPO_ROOT/source/LiveBench}"
[ -d "$LIVEBENCH_REPO" ] || { echo "LiveBench repo not found at $LIVEBENCH_REPO — see ONE-TIME SETUP in this script's header." >&2; exit 2; }

MODEL=""; SERVED_NAME=""; LIVEBENCH_MODEL=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
LB_MODEL="${LIVEBENCH_MODEL:-$SERVED_NAME}"   # name passed to --model; must match the served name
: "${AHL_HOST:=127.0.0.1}"; : "${AHL_PORT:=8000}"
BENCH="${2:-${BENCH:-live_bench/reasoning}}"   # general/reasoning slice; use 'live_bench' for the full set
MAX_TOKENS="${MAX_TOKENS:-32768}"; PARALLEL="${PARALLEL:-16}"

ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-livebench"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"; SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
TSV="$OUT_DIR/accuracy.tsv"

echo "== LiveBench: $LB_MODEL on $BENCH @ http://$AHL_HOST:$AHL_PORT (release=${RELEASE:-default}) ==" >&2
# run_livebench.py does inference + ground-truth grading + result display in one pass.
( cd "$LIVEBENCH_REPO" && uv run python -m livebench.run_livebench \
    --model "$LB_MODEL" --api-base "http://$AHL_HOST:$AHL_PORT/v1" --api-key none \
    --bench-name "$BENCH" --max-tokens "$MAX_TOKENS" --parallel-requests "$PARALLEL" \
    ${RELEASE:+--livebench-release-option "$RELEASE"} ) >"$BUNDLE/run.log" 2>&1 \
  || { echo "livebench run failed — see $BUNDLE/run.log" >&2; tail -8 "$BUNDLE/run.log" >&2; exit 1; }

# Parse the overall average score from the run output (LiveBench prints a per-category table + average).
# Best-effort — VALIDATE on first real run and tighten (LiveBench writes csv under its data/ dir too).
SCORE="$(grep -aoiE 'average[^0-9]*([0-9]+\.[0-9]+)' "$BUNDLE/run.log" | grep -oE '[0-9]+\.[0-9]+' | tail -1)"
SCORES="livebench_${BENCH//\//_}=${SCORE:-na}"
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
  "general_lb" "$BENCH${RELEASE:+@$RELEASE}" "full" "$SCORES" "$DATA_REL" "na" "${CONC:-na}" "na" "na" "na" >> "$TSV"
echo "row -> $TSV" >&2
