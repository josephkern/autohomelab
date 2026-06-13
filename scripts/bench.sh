#!/usr/bin/env bash
# bench.sh — run the GuideLLM tok/s sweep against a live endpoint and append a results.tsv row.
#
#   scripts/bench.sh <runbook.sh> [shape]
#
# shape ∈ chat (512/256, default) | coder (4096/1024); or set PROMPT/OUTPUT directly.
# The server must already be up (scripts/serve.sh <runbook.sh>).
#
# Uses GuideLLM's `concurrent` profile with one stage per concurrency level — NOT `sweep`,
# which ramps in-flight requests toward 512 that never drain for non-trivial outputs, so every
# request is cancelled at the time limit and throughput collapses to zero. (Lesson from the
# prior old-homelab harness.) MAX_SECONDS stays high so each stage completes enough requests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

RUNBOOK="${1:?usage: bench.sh <runbook.sh> [shape]}"
SHAPE="${2:-${SHAPE:-chat}}"
[ -f "$RUNBOOK" ] || { echo "runbook not found: $RUNBOOK" >&2; exit 1; }

# Fixed by the charter; the results.tsv columns assume exactly these 5 levels.
CONCURRENCY="1,4,8,16,32"
MAX_SECONDS="${MAX_SECONDS:-180}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"

case "$SHAPE" in
  chat)  PROMPT="${PROMPT:-512}";  OUTPUT="${OUTPUT:-256}" ;;
  coder) PROMPT="${PROMPT:-4096}"; OUTPUT="${OUTPUT:-1024}" ;;
  *)     PROMPT="${PROMPT:?set PROMPT for custom shape}"; OUTPUT="${OUTPUT:?set OUTPUT}" ;;
esac

# Identity for the row.
MODEL=""; SERVED_NAME=""; VLLM_FLAGS=()
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"
NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
: "${NODE_FP:?no node profile — run scripts/probe.sh first}"

"$ADAPTER" health >/dev/null 2>&1 || { echo "endpoint not healthy at $TARGET — run serve.sh first" >&2; exit 1; }

RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
BACKEND="$("$ADAPTER" info)"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
BUNDLE="$OUT_DIR/data/$RUN_ID"
mkdir -p "$BUNDLE"

# Synthetic shape spread around the means so each level mixes request sizes like real traffic.
DATA="prompt_tokens=${PROMPT},prompt_tokens_stdev=$((PROMPT/4)),prompt_tokens_min=$((PROMPT/2)),prompt_tokens_max=$((PROMPT*2)),"
DATA+="output_tokens=${OUTPUT},output_tokens_stdev=$((OUTPUT/4)),output_tokens_min=$((OUTPUT/4)),output_tokens_max=$((OUTPUT*2))"

echo "== guidellm $SHAPE (p$PROMPT/o$OUTPUT) @ $CONCURRENCY -> $TARGET ==" >&2
( cd "$BUNDLE" && uv run --project "$REPO_ROOT" guidellm benchmark run \
    --target "$TARGET" --profile concurrent --rate "$CONCURRENCY" \
    --data "$DATA" --max-seconds "$MAX_SECONDS" \
    --output-path "$BUNDLE/benchmarks.json" )

JSON="$BUNDLE/benchmarks.json"
[ -f "$JSON" ] || { echo "guidellm produced no benchmarks.json" >&2; exit 1; }

# output_tokens_per_second.successful.mean per stage, index-mapped to 1,4,8,16,32.
mapfile -t TPS < <(jq -r '.benchmarks[].metrics.output_tokens_per_second.successful.mean
                          | (.*100|round)/100' "$JSON")
[ "${#TPS[@]}" -eq 5 ] || echo "warn: expected 5 stages, got ${#TPS[@]}" >&2
PEAK_GB="$("$ADAPTER" peakmem)"
STATUS="${STATUS:-measured}"
NOTES="${NOTES:-}"
SHAPE_TAG="${SHAPE}(${PROMPT}/${OUTPUT})"
DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"

TSV="$OUT_DIR/results.tsv"
HEADER=$'run_id\tcommit\tnode_fp\tmodel\tshape\tbackend\tconfig_hash\tscript\ttps_c1\ttps_c4\ttps_c8\ttps_c16\ttps_c32\tpeak_gb\tstatus\tnotes\tdata'
[ -f "$TSV" ] || echo "$HEADER" > "$TSV"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$SHAPE_TAG" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" \
  "${TPS[0]:-na}" "${TPS[1]:-na}" "${TPS[2]:-na}" "${TPS[3]:-na}" "${TPS[4]:-na}" \
  "$PEAK_GB" "$STATUS" "$NOTES" "$DATA_REL" >> "$TSV"

echo >&2
echo "tok/s (output) c1=${TPS[0]:-na} c4=${TPS[1]:-na} c8=${TPS[2]:-na} c16=${TPS[3]:-na} c32=${TPS[4]:-na}" >&2
echo "row -> $(realpath --relative-to="$REPO_ROOT" "$TSV")" >&2
echo "raw -> $DATA_REL" >&2
