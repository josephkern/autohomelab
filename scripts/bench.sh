#!/usr/bin/env bash
# bench.sh — run GuideLLM tok/s sweeps against a live endpoint and append results.tsv row(s).
#
#   scripts/bench.sh <runbook.sh> [shape ...]
#
# shapes ∈ chat (512/256, default) | coder (4096/1024); pass several to AMORTIZE the model load
# across one serve session (the server is loaded once; each shape is a separate sweep + row).
# The server must already be up (scripts/serve.sh <runbook.sh>).
#
# Uses GuideLLM's `concurrent` profile (one stage per concurrency level) — NOT `sweep`, which
# ramps in-flight requests that never drain for non-trivial outputs (tok/s collapses to zero).
#
# Monitoring: a stall-watchdog (vLLM gen-throughput 0 with reqs running for STALL_SECS) + a hard
# timeout kill a hung pass, log a status=crash row, and tear the container down for clean recovery
# — a hang becomes a fast logged data point, not a multi-minute stall. (GuideLLM --max-seconds only
# bounds *scheduling*; it drains in-flight requests, so a wedged engine blocks past it.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

RUNBOOK="${1:?usage: bench.sh <runbook.sh> [shape ...]}"; shift || true
SHAPES=("$@"); [ "${#SHAPES[@]}" -eq 0 ] && SHAPES=("${SHAPE:-chat}")
[ -f "$RUNBOOK" ] || { echo "runbook not found: $RUNBOOK" >&2; exit 1; }

CONCURRENCY="1,4,8,16,32"                 # fixed by charter; results.tsv has exactly these columns
MAX_SECONDS="${MAX_SECONDS:-180}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
CONTAINER=ahl-vllm
STALL_SECS="${STALL_SECS:-90}"
N_LEVELS=$(($(grep -o ',' <<<"$CONCURRENCY" | wc -l) + 1))
PASS_TIMEOUT="${PASS_TIMEOUT:-$(( N_LEVELS * MAX_SECONDS * 2 + 240 ))}"

# ── Identity (computed once; same for every shape in this serve session) ───────
MODEL=""; SERVED_NAME=""; VLLM_FLAGS=()
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
: "${NODE_FP:?no node profile — run scripts/probe.sh first}"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
BACKEND="$("$ADAPTER" info)"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
TSV="$OUT_DIR/results.tsv"
HEADER=$'run_id\tcommit\tnode_fp\tmodel\tshape\tbackend\tconfig_hash\tscript\tload_s\ttps_c1\ttps_c4\ttps_c8\ttps_c16\ttps_c32\tpeak_gb\tstatus\tnotes\tdata'

# Load tax recorded by serve.sh (same for all shapes this session).
LOAD_S="na"
if [ -f "$REPO_ROOT/.ahl_serve_state" ]; then
  RUNBOOK_SERVED=""; LOAD_S=""
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.ahl_serve_state"
  [ "${RUNBOOK_SERVED:-}" = "$(realpath "$RUNBOOK")" ] || LOAD_S="na"
  [ -z "$LOAD_S" ] && LOAD_S="na"
fi

"$ADAPTER" health >/dev/null 2>&1 || { echo "endpoint not healthy at $TARGET — run serve.sh first" >&2; exit 1; }

emit_row() {  # emit_row <run_id> <shape_tag> <data_rel> <status> <notes> <peak> <t1> <t4> <t8> <t16> <t32>
  [ -f "$TSV" ] || echo "$HEADER" > "$TSV"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$COMMIT" "$NODE_FP" "$MODEL" "$2" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" "$LOAD_S" \
    "${7:-na}" "${8:-na}" "${9:-na}" "${10:-na}" "${11:-na}" "$6" "$4" "$5" "$3" >> "$TSV"
}

watchdog() {
  local z=0
  while sleep 15; do
    if docker logs --since 25s "$CONTAINER" 2>&1 | grep -E 'generation throughput' | tail -1 \
         | grep -qE 'generation throughput: 0\.0.*Running: [1-9]'; then
      z=$((z + 15)); [ "$z" -ge "$STALL_SECS" ] && {
        echo "stalled ${z}s (gen=0, reqs running)" >"$1"; pkill -f 'guidellm benchmark run' 2>/dev/null || true; return; }
    else z=0; fi
  done
}

run_shape() {
  local shape="$1" prompt output
  case "$shape" in
    chat)  prompt="${PROMPT:-512}";  output="${OUTPUT:-256}" ;;
    coder) prompt="${PROMPT:-4096}"; output="${OUTPUT:-1024}" ;;
    *)     prompt="${PROMPT:?set PROMPT for custom shape}"; output="${OUTPUT:?set OUTPUT}" ;;
  esac
  local run_id shape_tag bundle data_rel data hit
  run_id="$(date -u +%Y%m%d-%H%M%S)-$shape"
  shape_tag="${shape}(${prompt}/${output})"
  bundle="$OUT_DIR/data/$run_id"; mkdir -p "$bundle"
  data_rel="$(realpath --relative-to="$REPO_ROOT" "$bundle")"
  hit="$bundle/.watchdog_hit"; rm -f "$hit"
  data="prompt_tokens=${prompt},prompt_tokens_stdev=$((prompt/4)),prompt_tokens_min=$((prompt/2)),prompt_tokens_max=$((prompt*2)),"
  data+="output_tokens=${output},output_tokens_stdev=$((output/4)),output_tokens_min=$((output/4)),output_tokens_max=$((output*2))"

  echo "== guidellm $shape (p$prompt/o$output) @ $CONCURRENCY -> $TARGET (timeout ${PASS_TIMEOUT}s, stall ${STALL_SECS}s) ==" >&2
  watchdog "$hit" & local wd=$!
  set +e
  ( cd "$bundle" && timeout "$PASS_TIMEOUT" uv run --project "$REPO_ROOT" guidellm benchmark run \
      --target "$TARGET" --model "$SERVED_NAME" --processor "$MODEL" \
      --profile concurrent --rate "$CONCURRENCY" \
      --data "$data" --max-seconds "$MAX_SECONDS" --output-path "$bundle/benchmarks.json" )
  local rc=$?
  set -e
  kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true

  local json="$bundle/benchmarks.json" peak
  peak="$("$ADAPTER" peakmem 2>/dev/null || echo na)"
  if [ -f "$hit" ] || [ "$rc" -ne 0 ] || [ ! -f "$json" ]; then
    local reason; reason="$([ -f "$hit" ] && cat "$hit" || echo "guidellm rc=$rc$([ "$rc" = 124 ] && echo ' (timeout)')")"
    echo "!! CRASH ($shape): $reason — tearing down for clean recovery" >&2
    emit_row "$run_id" "$shape_tag" "$data_rel" "crash" "${NOTES:+$NOTES; }$reason" "$peak"
    "$ADAPTER" down || true
    return 3
  fi
  local tps; mapfile -t tps < <(jq -r '.benchmarks[].metrics.output_tokens_per_second.successful.mean | (.*100|round)/100' "$json")
  emit_row "$run_id" "$shape_tag" "$data_rel" "${STATUS:-measured}" "${NOTES:-}" "$peak" \
    "${tps[0]:-na}" "${tps[1]:-na}" "${tps[2]:-na}" "${tps[3]:-na}" "${tps[4]:-na}"
  echo "  $shape tok/s c1=${tps[0]:-na} c4=${tps[1]:-na} c8=${tps[2]:-na} c16=${tps[3]:-na} c32=${tps[4]:-na}" >&2
}

rc_all=0
for shape in "${SHAPES[@]}"; do
  run_shape "$shape" || { rc_all=3; echo "stopping remaining shapes — server torn down after crash" >&2; break; }
done
echo >&2; echo "row(s) -> $(realpath --relative-to="$REPO_ROOT" "$TSV")  (load ${LOAD_S}s)" >&2
exit $rc_all
