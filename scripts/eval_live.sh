#!/usr/bin/env bash
# eval_live.sh <runbook.sh> <release-date YYYY-MM-DD> [bench] — contamination-FREE quality signal via
# a TIME-GATED benchmark (LiveBench), scored only on questions released ON/AFTER <release-date>.
# Set <release-date> to AFTER the model's training cutoff (from the model card) so the questions
# cannot have been trained on. Runs against our live OpenAI endpoint (serve.sh first).
#
# EXPERIMENTAL: first run clones+installs LiveBench into source/ (gitignored) — verify the CLI/output
# on first use. LiveCodeBench (code) needs its OpenAI-endpoint adapter extended (lcb_runner/lm_styles.py)
# — TODO for coder models. See docs/validation.md (Gate 2, tier 3).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
RUNBOOK="${1:?usage: eval_live.sh <runbook.sh> <release-date YYYY-MM-DD> [bench]}"
RELEASE="${2:?need a release-date (YYYY-MM-DD) AFTER the model training cutoff}"
BENCH="${3:-live_bench}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"

MODEL=""; SERVED_NAME=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
LB="$REPO_ROOT/source/livebench"; VENV="$REPO_ROOT/source/.venv-livebench"

"$SCRIPT_DIR/../backends/vllm/adapter.sh" health >/dev/null 2>&1 || { echo "endpoint not healthy — serve.sh first" >&2; exit 1; }

# One-time install (gitignored under source/).
if [ ! -d "$LB" ]; then
  echo ">> cloning LiveBench -> source/livebench" >&2
  git clone --depth 1 https://github.com/livebench/livebench "$LB"
fi
if [ ! -d "$VENV" ]; then
  echo ">> installing LiveBench into source/.venv-livebench" >&2
  uv venv "$VENV" >/dev/null
  ( cd "$LB" && uv pip install --python "$VENV" -e . >/dev/null )
fi
PY="$VENV/bin/python"

echo "== LiveBench ($BENCH) release>=$RELEASE -> $SERVED_NAME @ $TARGET ==" >&2
( cd "$LB" && "$PY" run_livebench.py \
    --model "$SERVED_NAME" --api-base "$TARGET/v1" --api-key "${OPENAI_API_KEY:-dummy}" \
    --bench-name "$BENCH" --livebench-release-option "$RELEASE" )
( cd "$LB" && "$PY" show_livebench_result.py --bench-name "$BENCH" --model-list "$SERVED_NAME" || true )

# Best-effort: pull an overall/average score from all_groups.csv into accuracy.tsv (provenance = the
# release date — the contamination guarantee). Verify the CSV path/column on first run.
CSV="$(find "$LB" -name all_groups.csv -newermt '-1 hour' 2>/dev/null | head -1)"
SCORE="$( [ -f "$CSV" ] && python3 -c "
import csv,sys
rows=list(csv.reader(open('$CSV')))
# last numeric cell of the row mentioning the served model / 'average', best-effort
print('livebench=see all_groups.csv')
" || echo 'livebench=na')"
CFG="$(sha256sum "$RUNBOOK" | cut -c1-8)"
TSV="$OUT_DIR/accuracy.tsv"
# accuracy.tsv is 16 columns since docs/validity-contract.md A9. This harness is not lm-eval and
# emits no `n-samples` bundle, so the Gate-2 predicate cannot be evaluated for its row: `samples`,
# `validity` and `status` are recorded as `na`, which contract A5 says is NEVER `ok` -- an
# unevaluable quality number is reported as unevaluable, not asserted clean. A legacy 12-column
# journal is migrated in place first, so this append can never widen a narrow file.
migrate_acc(){ [ -f "$1" ] && [ "$(head -1 "$1")" != "$2" ] && \
  python3 "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$1" --bundle-root "$REPO_ROOT" --write >&2
  return 0; }
# NOTE: this script wrote ELEVEN columns against a twelve-column header (no `think`) -- it was out
# of sync before A9, not because of it. Fixed here in passing.
# accuracy.tsv header comes from scripts/eval_validity.py — one definition, five
# callers. Five hard-coded copies is the exact defect issue #1 opened on.
HDR="$(uv run --project "$REPO_ROOT" python "$SCRIPT_DIR/eval_validity.py" accuracy-header \
        2>/dev/null || python3 "$SCRIPT_DIR/eval_validity.py" accuracy-header)"
migrate_acc "$TSV" "$HDR"
[ -f "$TSV" ] || printf '%s\n' "$HDR" > "$TSV"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y%m%d-%H%M%S)-live" "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" "$NODE_FP" "$MODEL" \
  "$CFG" "$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")" "livebench" "$BENCH" "rel>=$RELEASE" "$SCORE" \
  "source/livebench" "na" "${CONC:-na}" "na" "na" "na" >> "$TSV"
echo ">> recorded livebench row (release-gated >= $RELEASE). Detail: $CSV" >&2
