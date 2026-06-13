#!/usr/bin/env bash
# bench.sh — run GuideLLM tok/s sweeps against a live endpoint and append results.tsv row(s).
#
#   scripts/bench.sh <runbook.sh> [shape ...]
#
# shapes ∈ chat (512/256, default) | coder (4096/1024); pass several to AMORTIZE the model load
# across one serve session (server loaded once; each shape = one row with the 1/4/8/16/32 curve).
# The server must already be up (scripts/serve.sh <runbook.sh>).
#
# PER-LEVEL ISOLATION: each concurrency level is a SEPARATE GuideLLM call, so a hang at a high
# level still preserves the lower levels' numbers (GuideLLM writes its JSON only at the end of a
# call) and pinpoints exactly which level breaks. Levels run low→high; on a hang we record that
# level as `hang`, keep the completed levels, tear the container down, and stop (hangs are at high
# concurrency, so higher levels would wedge too). This mirrors running each config by hand.
#
# Monitoring per level: stall-watchdog (vLLM gen-throughput 0 with reqs running for STALL_SECS) +
# a hard timeout. GuideLLM --max-seconds only bounds *scheduling*; it drains in-flight requests,
# so a wedged engine blocks past it — hence the external guards.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$REPO_ROOT/backends/vllm/adapter.sh"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

RUNBOOK="${1:?usage: bench.sh <runbook.sh> [shape ...]}"; shift || true
SHAPES=("$@"); [ "${#SHAPES[@]}" -eq 0 ] && SHAPES=("${SHAPE:-chat}")
[ -f "$RUNBOOK" ] || { echo "runbook not found: $RUNBOOK" >&2; exit 1; }

# Routine matrix is lean (c1 sentinel + c16 bulk objective). Full characterization sweep:
#   LEVELS_SET=1,4,8,16,32 scripts/bench.sh ...
# results.tsv always has the 5 fixed columns; unrun levels stay `na` so runs stay comparable.
IFS=',' read -ra LEVELS <<< "${LEVELS_SET:-1,16}"
col_index() { case "$1" in 1) echo 0;; 4) echo 1;; 8) echo 2;; 16) echo 3;; 32) echo 4;; *) echo -1;; esac; }
MAX_SECONDS="${MAX_SECONDS:-180}"
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
CONTAINER=ahl-vllm
STALL_SECS="${STALL_SECS:-90}"
LEVEL_TIMEOUT="${LEVEL_TIMEOUT:-$(( MAX_SECONDS * 2 + 120 ))}"
SEED="${AHL_SEED:-42}"                      # fixed -> same synthetic prompts across configs (paired)

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
HEADER=$'run_id\tcommit\tnode_fp\tmodel\tshape\tbackend\tconfig_hash\tscript\tload_s\tmax_s\tseed\ttps_c1\ttps_c4\ttps_c8\ttps_c16\ttps_c32\tpeak_gb\tstatus\tnotes\tdata'

# Load tax recorded by serve.sh (same for all shapes this session).
LOAD_S="na"
if [ -f "$REPO_ROOT/.ahl_serve_state" ]; then
  RUNBOOK_SERVED=""; LOAD_S=""
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.ahl_serve_state"
  { [ "${RUNBOOK_SERVED:-}" = "$(realpath "$RUNBOOK")" ] && [ -n "$LOAD_S" ]; } || LOAD_S="na"
fi

"$ADAPTER" health >/dev/null 2>&1 || { echo "endpoint not healthy at $TARGET — run serve.sh first" >&2; exit 1; }

emit_row() {  # emit_row <run_id> <shape_tag> <data_rel> <status> <notes> <peak> <t1> <t4> <t8> <t16> <t32>
  [ -f "$TSV" ] || echo "$HEADER" > "$TSV"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$COMMIT" "$NODE_FP" "$MODEL" "$2" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" "$LOAD_S" "$MAX_SECONDS" "$SEED" \
    "${7:-na}" "${8:-na}" "${9:-na}" "${10:-na}" "${11:-na}" "$6" "$4" "$5" "$3" >> "$TSV"
}

watchdog() {  # watchdog <hit_file>
  local z=0
  while sleep 15; do
    if docker logs --since 25s "$CONTAINER" 2>&1 | grep -E 'generation throughput' | tail -1 \
         | grep -qE 'generation throughput: 0\.0.*Running: [1-9]'; then
      z=$((z + 15)); [ "$z" -ge "$STALL_SECS" ] && {
        echo "stalled ${z}s (gen=0, reqs running)" >"$1"; pkill -f 'guidellm benchmark run' 2>/dev/null || true; return; }
    else z=0; fi
  done
}

# run_level <bundle> <level> <data>: sets TPS_OUT; returns 0 ok / 3 crash. JSON kept per level.
run_level() {
  local bundle="$1" level="$2" data="$3" hit="$1/.wd_c$2" json="$1/level_c$2.json"; rm -f "$hit"; TPS_OUT="hang"
  watchdog "$hit" & local wd=$!
  set +e
  ( cd "$bundle" && timeout "$LEVEL_TIMEOUT" uv run --project "$REPO_ROOT" guidellm benchmark run \
      --target "$TARGET" --model "$SERVED_NAME" --processor "$MODEL" --random-seed "$SEED" \
      --profile concurrent --rate "$level" \
      --data "$data" --max-seconds "$MAX_SECONDS" --output-path "$json" ) >"$bundle/level_c$level.log" 2>&1
  local rc=$?
  set -e
  kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
  { [ -f "$hit" ] || [ "$rc" -ne 0 ] || [ ! -f "$json" ]; } && return 3
  TPS_OUT="$(jq -r '.benchmarks[0].metrics.output_tokens_per_second.successful.mean | (.*100|round)/100' "$json")"
  return 0
}

run_shape() {
  local shape="$1" prompt output
  case "$shape" in
    chat)  prompt="${PROMPT:-512}";  output="${OUTPUT:-256}" ;;
    coder) prompt="${PROMPT:-4096}"; output="${OUTPUT:-1024}" ;;
    *)     prompt="${PROMPT:?set PROMPT for custom shape}"; output="${OUTPUT:?set OUTPUT}" ;;
  esac
  local run_id shape_tag bundle data_rel data
  run_id="$(date -u +%Y%m%d-%H%M%S)-$shape"
  shape_tag="${shape}(${prompt}/${output})"
  bundle="$OUT_DIR/data/$run_id"; mkdir -p "$bundle"
  data_rel="$(realpath --relative-to="$REPO_ROOT" "$bundle")"
  data="prompt_tokens=${prompt},prompt_tokens_stdev=$((prompt/4)),prompt_tokens_min=$((prompt/2)),prompt_tokens_max=$((prompt*2)),"
  data+="output_tokens=${output},output_tokens_stdev=$((output/4)),output_tokens_min=$((output/4)),output_tokens_max=$((output*2))"

  echo "== $shape (p$prompt/o$output) per-level sweep @ c${LEVELS[*]} (max_s=$MAX_SECONDS, seed=$SEED, stall=$STALL_SECS) ==" >&2
  # Sidecar: sample GPU power/temp/util for the whole shape sweep (thermal is a tok/s confounder).
  local sp=""; "$SCRIPT_DIR/metrics_sampler.sh" "$bundle/gpu_metrics.csv" 5 >/dev/null 2>&1 & sp=$!
  local -a tps=(na na na na na); local level idx crashed=0 crash_level=""
  for level in "${LEVELS[@]}"; do
    idx="$(col_index "$level")"; [ "$idx" -lt 0 ] && { echo "  skip invalid level $level" >&2; continue; }
    echo "  -- c$level --" >&2
    if run_level "$bundle" "$level" "$data"; then
      tps[$idx]="$TPS_OUT"; echo "     c$level tok/s=$TPS_OUT" >&2
    else
      tps[$idx]="hang"; crashed=1; crash_level="$level"
      echo "  !! c$level hung/crashed — keeping lower levels, tearing down" >&2; break
    fi
  done

  kill "$sp" 2>/dev/null || true; wait "$sp" 2>/dev/null || true
  local peak status notes thermal
  peak="$("$ADAPTER" peakmem 2>/dev/null || echo na)"
  thermal="$("$SCRIPT_DIR/metrics_sampler.sh" --summary "$bundle/gpu_metrics.csv" 2>/dev/null || echo thermal=na)"
  if [ "$crashed" = 1 ]; then status="crash"; notes="${NOTES:+$NOTES; }hang@c$crash_level; $thermal"
  else status="${STATUS:-measured}"; notes="${NOTES:+$NOTES; }$thermal"; fi
  emit_row "$run_id" "$shape_tag" "$data_rel" "$status" "$notes" "$peak" \
    "${tps[0]}" "${tps[1]}" "${tps[2]}" "${tps[3]}" "${tps[4]}"
  echo "  $shape -> c1=${tps[0]} c4=${tps[1]} c8=${tps[2]} c16=${tps[3]} c32=${tps[4]}  [$status]" >&2
  [ "$crashed" = 1 ] && { "$ADAPTER" down || true; return 3; }
  return 0
}

rc_all=0
for shape in "${SHAPES[@]}"; do
  run_shape "$shape" || { rc_all=3; echo "stopping remaining shapes — server torn down after crash" >&2; break; }
done
echo >&2; echo "row(s) -> $(realpath --relative-to="$REPO_ROOT" "$TSV")  (load ${LOAD_S}s)" >&2
exit $rc_all
