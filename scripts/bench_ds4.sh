#!/usr/bin/env bash
# bench_ds4.sh — GuideLLM tok/s sweep against a live ds4-server (antirez/ds4 "DwarfStar")
# and append results.tsv row(s) in the standard schema. ds4 is a HOST-process backend (no
# docker adapter), so this is a lean sibling of bench.sh: same GuideLLM invocation, same
# per-level isolation + hard timeout, same columns; backend = ds4@<git-short-sha>.
#
#   TAG=<config-slug> scripts/bench_ds4.sh [shape ...]      # server must already be up
#
# DSpark only engages on GREEDY requests, and ds4-server's default is temperature 1.0 —
# so every request injects temperature via GuideLLM extras (TEMP, default 0). This also
# de-noises the A/B: all ds4 rows are greedy unless TEMP is overridden.
#
# Env: TAG (required, lands in notes), LEVELS_SET (default 1), MAX_SECONDS (180), SEED (42),
#      TEMP (0), AHL_HOST/AHL_PORT (127.0.0.1:8000), DS4_DIR (~/code/ds4), NOTES (extra note text).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${TAG:?set TAG=<config-slug> (e.g. baseline, dspark, batch4)}"
SHAPES=("$@"); [ "${#SHAPES[@]}" -eq 0 ] && SHAPES=("${SHAPE:-chat}")
IFS=',' read -ra LEVELS <<< "${LEVELS_SET:-1}"
col_index() { case "$1" in 1) echo 0;; 4) echo 1;; 8) echo 2;; 16) echo 3;; 32) echo 4;; *) echo -1;; esac; }
MAX_SECONDS="${MAX_SECONDS:-180}"
SEED="${SEED:-42}"
TEMP="${TEMP:-0}"
TARGET="http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}"
LEVEL_TIMEOUT="${LEVEL_TIMEOUT:-$(( MAX_SECONDS * 3 + 180 ))}"
DS4_DIR="${DS4_DIR:-$HOME/code/ds4}"

# ── Identity ──────────────────────────────────────────────────────────────────
ORG="antirez"; NAME="DeepSeek-V4-Flash"
SERVED_NAME="deepseek-v4-flash"
PROCESSOR="${PROCESSOR:-deepseek-ai/DeepSeek-V4-Flash}"   # HF tokenizer for synthetic data
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
: "${NODE_FP:?no node profile — run scripts/probe.sh first}"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
DS4_SHA="$(git -C "$DS4_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BACKEND="ds4@${DS4_SHA}"
SCRIPT_REL="launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh"

# config_hash: hash the RUNNING server's actual cmdline (captures flags incl. --dspark/--batched-session)
SRV_PID="$(pgrep -f 'ds4-server .*--port '"${AHL_PORT:-8000}" | head -1 || true)"
[ -n "$SRV_PID" ] || { echo "no ds4-server running on port ${AHL_PORT:-8000}" >&2; exit 1; }
SRV_CMD="$(tr '\0' ' ' < "/proc/$SRV_PID/cmdline")"
CONFIG_HASH="$(printf '%s' "$SRV_CMD" | sha256sum | cut -c1-8)"

OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
TSV="$OUT_DIR/results.tsv"
mkdir -p "$OUT_DIR/data"
HEADER=$'run_id\tcommit\tnode_fp\tmodel\tshape\tbackend\tconfig_hash\tscript\tload_s\tmax_s\tseed\ttps_c1\ttps_c4\ttps_c8\ttps_c16\ttps_c32\tpeak_gb\tstatus\tnotes\tdata'
[ -f "$TSV" ] || printf '%s\n' "$HEADER" > "$TSV"

peak_gb() { awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f",(t-a)/1048576}' /proc/meminfo; }

run_level() {  # <bundle> <level> <data>: sets TPS_OUT; returns 0 ok / 3 crash
  local bundle="$1" level="$2" data="$3" json="$1/level_c$2.json"; TPS_OUT="hang"
  set +e
  ( cd "$bundle" && timeout "$LEVEL_TIMEOUT" uv run --project "$REPO_ROOT" guidellm benchmark run \
      --target "$TARGET" --model "$SERVED_NAME" --processor "$PROCESSOR" --random-seed "$SEED" \
      --backend-kwargs "{\"extras\": {\"body\": {\"temperature\": $TEMP}}, \"validate_backend\": \"$TARGET/v1/models\"}" \
      --profile concurrent --rate "$level" \
      --data "$data" --max-seconds "$MAX_SECONDS" --output-path "$json" ) >"$bundle/level_c$level.log" 2>&1
  local rc=$?
  set -e
  { [ "$rc" -ne 0 ] || [ ! -f "$json" ]; } && return 3
  TPS_OUT="$(jq -r '.benchmarks[0].metrics.output_tokens_per_second.successful.mean | (.*100|round)/100' "$json")"
  return 0
}

for shape in "${SHAPES[@]}"; do
  case "$shape" in
    chat)  prompt=512;  output=256 ;;
    coder) prompt=4096; output=1024 ;;
    *)     prompt="${PROMPT:?}"; output="${OUTPUT:?}" ;;
  esac
  run_id="$(date -u +%Y%m%d-%H%M%S)-$shape"
  shape_tag="${shape}(${prompt}/${output})"
  bundle="$OUT_DIR/data/$run_id"; mkdir -p "$bundle"
  data_rel="results/$NODE_FP/$ORG/$NAME/data/$run_id"
  data="prompt_tokens=${prompt},prompt_tokens_stdev=$((prompt/4)),prompt_tokens_min=$((prompt/2)),prompt_tokens_max=$((prompt*2)),"
  data+="output_tokens=${output},output_tokens_stdev=$((output/4)),output_tokens_min=$((output/4)),output_tokens_max=$((output*2))"

  echo "== ds4 $TAG: $shape (p$prompt/o$output) @ c${LEVELS[*]} (max_s=$MAX_SECONDS, seed=$SEED, temp=$TEMP) ==" >&2
  tps=(na na na na na); status="measured"; peak=0
  for level in "${LEVELS[@]}"; do
    idx="$(col_index "$level")"; [ "$idx" -ge 0 ] || continue
    if run_level "$bundle" "$level" "$data"; then
      tps[idx]="$TPS_OUT"
      echo "   c$level = $TPS_OUT tok/s" >&2
    else
      tps[idx]="hang"; status="crash"
      echo "   c$level = CRASH/hang (see $bundle/level_c$level.log)" >&2
      break
    fi
    p="$(peak_gb)"; awk -v a="$p" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$p"
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$COMMIT" "$NODE_FP" "$ORG/$NAME" "$shape_tag" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" \
    "na" "$MAX_SECONDS" "$SEED" "${tps[0]}" "${tps[1]}" "${tps[2]}" "${tps[3]}" "${tps[4]}" \
    "$peak" "$status" "cfg=$TAG temp=$TEMP${NOTES:+ $NOTES}" "$data_rel" >> "$TSV"
  echo "row appended: $TSV ($run_id, $status)" >&2
done
