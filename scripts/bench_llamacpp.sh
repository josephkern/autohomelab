#!/usr/bin/env bash
# bench_llamacpp.sh — GuideLLM tok/s sweep against a live llama-server (ggml-org/llama.cpp) and
# append results.tsv row(s) in the standard schema. llama.cpp is a HOST-process backend (no docker
# adapter), so this is a lean sibling of bench.sh — same GuideLLM invocation, same per-level
# isolation + hard timeout, same columns; backend = llamacpp@<git-short-sha>.
#
#   TAG=<config-slug> scripts/bench_llamacpp.sh <runbook-stub.sh> [shape ...]   # server must be up
#
# Unlike bench_ds4.sh (which hardcodes DeepSeek-V4-Flash), identity comes from the runbook STUB —
# the same file smoke.sh and eval.sh source — so one stub drives all three gates:
#   MODEL        journal identity (HF repo of the GGUF), lands in the model column
#   SERVED_NAME  the id llama-server reports at /v1/models (its -a/--alias)
#   PROCESSOR    HF repo with a real tokenizer for GuideLLM synthetic text. GGUF repos ship no
#                tokenizer.json, so this MUST point at the unquantized source repo (cf. bench_ds4.sh).
#
# llama.cpp serves N concurrent requests from -np parallel slots; requests beyond -np QUEUE rather
# than batch. Benchmarking c16 against a -np 1 server measures the queue, not the engine — the
# launcher's NP must cover the highest level in LEVELS_SET. This script warns when it can detect a
# mismatch from the server cmdline.
#
# Env: TAG (required, lands in notes), LEVELS_SET (default 1,16), MAX_SECONDS (180), SEED (42),
#      TEMP (0 — pinned greedy so A/Bs are de-noised; llama.cpp's own default is the model's),
#      AHL_HOST/AHL_PORT (127.0.0.1:8000), LCPP_DIR (~/code/llama.cpp), NOTES (extra note text).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

TAG="${TAG:?set TAG=<config-slug> (e.g. q5km-mtp, q5km-regular, np16)}"
STUB="${1:?usage: TAG=<slug> bench_llamacpp.sh <runbook-stub.sh> [shape ...]}"; shift || true
SHAPES=("$@"); [ "${#SHAPES[@]}" -eq 0 ] && SHAPES=("${SHAPE:-chat}")
IFS=',' read -ra LEVELS <<< "${LEVELS_SET:-1,16}"
col_index() { case "$1" in 1) echo 0;; 4) echo 1;; 8) echo 2;; 16) echo 3;; 32) echo 4;; *) echo -1;; esac; }
MAX_SECONDS="${MAX_SECONDS:-180}"
SEED="${SEED:-42}"
TEMP="${TEMP:-0}"
TARGET="http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}"
LEVEL_TIMEOUT="${LEVEL_TIMEOUT:-$(( MAX_SECONDS * 3 + 180 ))}"
LCPP_DIR="${LCPP_DIR:-$HOME/code/llama.cpp}"

# ── Identity (from the stub — shared with smoke.sh / eval.sh) ─────────────────
MODEL=""; SERVED_NAME=""; PROCESSOR=""
# shellcheck disable=SC1090
source "$STUB"
: "${MODEL:?stub must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
: "${PROCESSOR:?stub must set PROCESSOR (HF repo with a tokenizer — GGUF repos have none)}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"

NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
: "${NODE_FP:?no node profile — run scripts/probe.sh first}"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
LCPP_SHA="$(git -C "$LCPP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BACKEND="llamacpp@${LCPP_SHA}"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$STUB")"

# config_hash: hash the RUNNING server's actual cmdline (captures the GGUF path + every flag).
SRV_PID="$(pgrep -f "llama-server .*--port ${AHL_PORT:-8000}" | head -1 || true)"
[ -n "$SRV_PID" ] || { echo "no llama-server running on port ${AHL_PORT:-8000}" >&2; exit 1; }
SRV_CMD="$(tr '\0' ' ' < "/proc/$SRV_PID/cmdline")"
CONFIG_HASH="$(printf '%s' "$SRV_CMD" | sha256sum | cut -c1-8)"

# Record which GGUF is actually loaded — the campaign's primary axis is the quant file itself.
GGUF="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=-m )\S+' | head -1 || true)"
QUANT="$(basename "${GGUF:-unknown}" .gguf)"

# -np sanity: benchmarking above the slot count measures queueing, not throughput.
NP="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=-np )\d+|(?<=--parallel )\d+' | head -1 || true)"
MAXLVL=0; for l in "${LEVELS[@]}"; do [ "$l" -gt "$MAXLVL" ] && MAXLVL="$l"; done
if [ -n "$NP" ] && [ "$NP" -lt "$MAXLVL" ]; then
  echo "WARNING: server has -np $NP but LEVELS_SET tops out at c$MAXLVL —" >&2
  echo "         levels above $NP measure queue latency, not engine throughput." >&2
fi

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

  echo "== llamacpp $TAG: $shape (p$prompt/o$output) @ c${LEVELS[*]} (max_s=$MAX_SECONDS, seed=$SEED, temp=$TEMP) ==" >&2
  echo "   gguf: $QUANT${NP:+  np=$NP}" >&2
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
    "$peak" "$status" "cfg=$TAG quant=$QUANT${NP:+ np=$NP} temp=$TEMP${NOTES:+ $NOTES}" "$data_rel" >> "$TSV"
  echo "row appended: $TSV ($run_id, $status)" >&2
done
