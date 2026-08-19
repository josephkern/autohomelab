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
# VALIDITY (docs/validity-contract.md): the row carries req_counts/validity/knobs and the
# status is downgraded to `suspect`/`void` when the invariants fail; exit 4 = "the numbers are
# not citable", exit 3 = "the box broke" (a crash outranks a validity verdict). The verdict
# rules live ONLY in scripts/lib/validity.py behind the scripts/lib/validity.sh shim — nothing
# here re-implements them.
#
# `knobs` is where a host-process backend earns its provenance: config_hash is computed from the
# runbook stub, which carries no launcher settings at all, so two ds4 configs that differ in
# --dspark/--ctx/--batched-session share a hash (AGENTS.md follow-up). The knob string below is
# read off the RUNNING server's cmdline AND its DS4_DSPARK*/DS4_MTP* environment (DSpark's runtime
# knobs are env vars the cmdline never shows), so the row records what actually varied.
#
# Env: TAG (required, lands in notes), LEVELS_SET (default 1), MAX_SECONDS (180), SEED (42),
#      TEMP (0), AHL_HOST/AHL_PORT (127.0.0.1:8000), DS4_DIR (~/code/ds4), NOTES (extra note text).
#      Validity thresholds (AHL_MIN_DATA / AHL_MIN_SUCCESSFUL / AHL_MIN_MODEL_GB) are read by the
#      library, not here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Validity library (docs/validity-contract.md §1 — the ONLY implementation of the rules):
#   $AHL_RESULTS_HEADER                              the 23-column header string
#   ahl_validity <bundle_dir> <levels_csv> <tps_csv> stdout "<req_counts>\t<validity>";
#                                                    exit 0=ok 1=suspect 2=fatal.
#   levels_csv/tps_csv are PARALLEL over the levels actually attempted (a hung level appears with
#   tps `hang` and no json). Sourced, so it may read REPO_ROOT/NODE_FP from this scope.
[ -f "$SCRIPT_DIR/lib/validity.sh" ] || { echo "missing scripts/lib/validity.sh — see docs/validity-contract.md" >&2; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validity.sh"

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

# ── Effective launcher knobs (the `knobs` column) ─────────────────────────────
# Same grep-off-the-cmdline style as CONFIG_HASH above, but recorded in plain text so a row is
# readable without re-deriving anything. config_hash says "different"; these say "different HOW".
GGUF="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=-m )\S+' | head -1 || true)"
SRV_QUANT="$(basename "${GGUF:-unknown}" .gguf)"
SRV_CTX="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--ctx )\d+' | head -1 || true)"
SRV_MTP="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--mtp )\S+' | head -1 || true)"
SRV_MTP="$([ -n "$SRV_MTP" ] && basename "$SRV_MTP" .gguf || echo na)"
SRV_MTP_DRAFT="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--mtp-draft )\d+' | head -1 || true)"
SRV_DSPARK_CONF="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--dspark-confidence )\S+' | head -1 || true)"
SRV_BATCH="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--batched-session )\d+' | head -1 || true)"
if   printf '%s' "$SRV_CMD" | grep -q -- '--dspark-strict'; then SRV_DSPARK="strict"
elif printf '%s' "$SRV_CMD" | grep -q -- '--dspark';        then SRV_DSPARK="on"
else                                                             SRV_DSPARK="off"; fi
# DSpark's scheduler/exec knobs are ENV vars, invisible to the cmdline (and to config_hash) — the
# launcher only echoes them to its log. Read them off the served process so the row keeps them.
SRV_ENV="$(tr '\0' '\n' < "/proc/$SRV_PID/environ" 2>/dev/null | grep -E '^(DS4_DSPARK|DS4_MTP)' | sort | tr ',\t' ';:' | paste -sd';' - || true)"

# GuideLLM version comes from the lockfile (charter: pinned) — no network, no venv resolution.
GLLM_VER="$(awk '/^name = "guidellm"$/{f=1} f && /^version = /{gsub(/"/,"",$3); print $3; exit}' "$REPO_ROOT/uv.lock" 2>/dev/null || true)"

OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
TSV="$OUT_DIR/results.tsv"
mkdir -p "$OUT_DIR/data"
[ -f "$TSV" ] || printf '%s\n' "$AHL_RESULTS_HEADER" > "$TSV"

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

rc_all=0
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

  # Effective knob set for THIS row: contract-order base knobs, then the ds4 launcher's own.
  # stall=na — a host process has no docker-log watchdog, so bench.sh's STALL_SECS has no analogue.
  knobs="levels=${LEVELS_SET:-1},max_s=$MAX_SECONDS,seed=$SEED,prompt=$prompt,output=$output"
  knobs+=",temp=$TEMP,stall=na,ltimeout=$LEVEL_TIMEOUT,gllm=${GLLM_VER:-na}"
  knobs+=",gguf=$SRV_QUANT,ctx=${SRV_CTX:-na},dspark=$SRV_DSPARK,dspark_conf=${SRV_DSPARK_CONF:-default}"
  knobs+=",mtp=$SRV_MTP,mtp_draft=${SRV_MTP_DRAFT:-na},batched_session=${SRV_BATCH:-off}"
  knobs+=",ds4_env=${SRV_ENV:-none}"

  echo "== ds4 $TAG: $shape (p$prompt/o$output) @ c${LEVELS[*]} (max_s=$MAX_SECONDS, seed=$SEED, temp=$TEMP) ==" >&2
  tps=(na na na na na); status="measured"; peak=0
  ran_levels=(); ran_tps=()          # parallel arrays over ATTEMPTED levels — the validity input
  for level in "${LEVELS[@]}"; do
    idx="$(col_index "$level")"; [ "$idx" -ge 0 ] || continue
    if run_level "$bundle" "$level" "$data"; then
      tps[idx]="$TPS_OUT"
      ran_levels+=("$level"); ran_tps+=("$TPS_OUT")
      echo "   c$level = $TPS_OUT tok/s" >&2
    else
      tps[idx]="hang"; status="crash"
      ran_levels+=("$level"); ran_tps+=("hang")   # a hung level WAS run: its missing json is a verdict
      echo "   c$level = CRASH/hang (see $bundle/level_c$level.log)" >&2
      break
    fi
    p="$(peak_gb)"; awk -v a="$p" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$p"
  done

  # Validity: rules live in the library. We consume the verdict, we do not classify it.
  set +e
  v_out="$(ahl_validity "$bundle" "$(IFS=,; echo "${ran_levels[*]-}")" "$(IFS=,; echo "${ran_tps[*]-}")")"
  v_rc=$?
  set -e
  case "$v_out" in
    *$'\t'*) req_counts="${v_out%%$'\t'*}"; validity="${v_out#*$'\t'}" ;;
    *)       req_counts="na"; validity="${v_out:-na}" ;;
  esac
  : "${req_counts:=na}"; : "${validity:=na}"     # contract: a column value is never empty
  case "$v_rc" in
    0) ;;
    1) [ "$status" = crash ] || status="suspect" ;;   # suspect verdict(s)
    *) [ "$status" = crash ] || status="void" ;;      # fatal verdict(s), or the library itself failed
  esac
  if [ "$status" = crash ]; then rc_all=3                       # the box broke: outranks validity
  elif [ "$v_rc" -ne 0 ] && [ "$rc_all" -eq 0 ]; then rc_all=4  # numbers are not citable
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$COMMIT" "$NODE_FP" "$ORG/$NAME" "$shape_tag" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" \
    "na" "$MAX_SECONDS" "$SEED" "${tps[0]}" "${tps[1]}" "${tps[2]}" "${tps[3]}" "${tps[4]}" \
    "$peak" "$req_counts" "$validity" "$knobs" \
    "$status" "cfg=$TAG temp=$TEMP${NOTES:+ $NOTES}" "$data_rel" >> "$TSV"
  echo "row appended: $TSV ($run_id, $status, validity=$validity, req=$req_counts)" >&2
done
exit "$rc_all"
