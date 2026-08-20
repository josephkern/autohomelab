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
# On a crash the sweep STOPS: remaining shapes are not benched against a wedged engine (that
# would write a citable `measured` row after the box broke). Forensics land in the bundle's
# engine_crash.log; the engine process itself is LEFT RUNNING for the operator unless
# AHL_KILL_ON_CRASH=1 (see the crash block near the end — this script does not own the process).
#
# VALIDITY (docs/validity-contract.md): the row carries req_counts/validity/knobs and the status
# is downgraded to `suspect`/`void` when the invariants fail; exit 4 = "the numbers are not
# citable", exit 3 = "the box broke" (a crash outranks a validity verdict). The verdict rules live
# ONLY in scripts/lib/validity.py behind the scripts/lib/validity.sh shim — nothing here
# re-implements them. This is the gate the FF711 coder sweep needed: 180 s at 4096/1024 on a
# ~20 tok/s dense model drained 2–5 requests per level and produced a curve (c1 27.57 -> c4 121.23
# -> c8 47.72) that looked like a measurement, was written `measured`, and was caught only by a
# human reading successful-counts out of the bundle afterwards.
#
# PROVENANCE. A host-process backend has no runbook to hash, so `config_hash` used to be computed
# from the runbook stub, which carries no launcher settings — two llama.cpp configs differing in
# NP/CTX/quant/spec shared a hash (AGENTS.md follow-up). It is now `scripts/lib/hostcfg.sh`'s
# `hp2-` hash over the SERVED process's argv, its LLAMA_*/GGML_* tuning environment and the engine
# build. `knobs` records the same facts in plain text, including the derived ctx_per_slot that
# makes the `CTX = CTX_PER_SLOT * NP` trap visible in the journal instead of only in the launcher.
#
# Env: TAG (required, lands in notes), LEVELS_SET (default 1,16), MAX_SECONDS (180), SEED (42),
#      TEMP (0 — pinned greedy so A/Bs are de-noised; llama.cpp's own default is the model's),
#      AHL_HOST/AHL_PORT (127.0.0.1:8000), LCPP_DIR (~/code/llama.cpp), NOTES (extra note text).
#      Validity thresholds (AHL_MIN_DATA / AHL_MIN_SUCCESSFUL / AHL_MIN_MODEL_GB) are read by the
#      library, not here.
#      AHL_KILL_ON_CRASH (0) / AHL_KILL_WAIT (15) — opt-in teardown of a wedged engine process.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
# Validity library (docs/validity-contract.md §1 — the ONLY implementation of the rules):
#   $AHL_RESULTS_HEADER   the 23-column header string
#   ahl_validity <bundle_dir> <levels_csv> <tps_csv> [--node-profile P] [--model-gb G]
#       -> "<validity>\t<req_counts>\t<status_floor>"   (status_floor ∈ ok|suspect|void)
#   levels_csv = the levels actually ATTEMPTED (a hung level is one of them: its missing json is
#   itself a verdict). tps_csv = the 5 fixed tps_c* cells c1,c4,c8,c16,c32 (`na`/`hang` accepted).
#   The status FLOOR is authoritative — severity is never derived from the exit code, which is
#   non-zero only when the library itself failed.
#   --model-gb is deliberately NOT passed: a GGUF's file size is the right bytes-per-token for a
#   dense model but wildly wrong for an MoE (a few active experts of a large file), and an
#   over-tight ceiling would void good rows. The library's loose default bound is the safe one.
[ -f "$SCRIPT_DIR/lib/validity.sh" ] || { echo "missing scripts/lib/validity.sh — see docs/validity-contract.md" >&2; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validity.sh"

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
ENGINE="${BACKEND%%@*}"   # `ds4` / `llamacpp` — used by the crash path
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$STUB")"

SRV_PID="$(pgrep -f "llama-server .*--port ${AHL_PORT:-8000}" | head -1 || true)"
[ -n "$SRV_PID" ] || { echo "no llama-server running on port ${AHL_PORT:-8000}" >&2; exit 1; }
SRV_CMD="$(tr '\0' ' ' < "/proc/$SRV_PID/cmdline")"
# llama.cpp's out-of-band knobs are LLAMA_*/GGML_* env vars (GGML_CUDA_* kernel selection,
# LLAMA_ARG_* — llama-server reads a documented LLAMA_ARG_ env for most of its flags, so a config
# can be set entirely OUTSIDE the cmdline and would otherwise be invisible to the hash).
HOSTCFG_ENV_RE='^(LLAMA_|GGML_)'

# ── config_hash — scheme `hp2` (scripts/lib/hostcfg.sh) ───────────────────────
# The identity of a host-process config is not a file: `serve.sh` never runs and the
# `.smoke-runbook.sh` stub the other gates hash carries no launcher settings, so every config of
# this engine hashed to the same 8 digits. It is computed instead from what actually determines
# the run — the served process's argv, the tuning env vars that never reach the cmdline, and the
# engine build — with pid, host, port, log paths and directories normalised away and both argv
# pairs and env sorted, so the SAME config re-serves to the SAME hash. The `hp2-` prefix versions
# the scheme: rows written before this change keep bare 8-hex and are never re-interpreted.
[ -f "$SCRIPT_DIR/lib/hostcfg.sh" ] || { echo "missing scripts/lib/hostcfg.sh" >&2; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hostcfg.sh"
CONFIG_HASH="$(ahl_hostcfg_hash "$SRV_PID" "$BACKEND" "$HOSTCFG_ENV_RE")" \
  || { echo "cannot read /proc/$SRV_PID — did the engine exit?" >&2; exit 1; }
# The tuning environment for the `knobs` column comes from the SAME extraction the hash consumed,
# so the human-readable knob and the identity can never disagree about what was set.
SRV_ENV="$(ahl_hostcfg_env_knob "$SRV_PID" "$HOSTCFG_ENV_RE")"

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

# ── Effective launcher knobs (the `knobs` column) ─────────────────────────────
# The same served cmdline the hash consumed, recorded in plain text so a row is readable without
# re-deriving anything. config_hash says "different"; these say "different HOW".
SRV_CTX="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=-c )\d+|(?<=--ctx-size )\d+' | head -1 || true)"
SRV_NGL="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=-ngl )\d+|(?<=--n-gpu-layers )\d+' | head -1 || true)"
SRV_FA="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=-fa )\S+|(?<=--flash-attn )\S+' | head -1 || true)"
SRV_SPEC="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--spec-type )\S+' | head -1 || true)"
SRV_DRAFT="$(printf '%s' "$SRV_CMD" | grep -oP '(?<=--spec-draft-n-max )\d+' | head -1 || true)"
# CTX is TOTAL across slots — the per-slot figure is the number that actually sizes KV, and the
# `CTX = CTX_PER_SLOT * NP` coupling is a documented foot-gun (raising NP alone doubles KV and
# swapped this box). Derive it so the journal shows it without re-reading the launcher.
SRV_CTX_PER_SLOT=na
if [ -n "$SRV_CTX" ] && [ -n "$NP" ] && [ "$NP" -gt 0 ]; then SRV_CTX_PER_SLOT=$(( SRV_CTX / NP )); fi
if printf '%s' "$SRV_CMD" | grep -q 'enable_thinking'; then SRV_THINK="off"; else SRV_THINK="on"; fi

# GuideLLM version comes from the lockfile (charter: pinned) — no network, no venv resolution.
GLLM_VER="$(awk '/^name = "guidellm"$/{f=1} f && /^version = /{gsub(/"/,"",$3); print $3; exit}' "$REPO_ROOT/uv.lock" 2>/dev/null || true)"

OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
TSV="$OUT_DIR/results.tsv"
mkdir -p "$OUT_DIR/data"
[ -f "$TSV" ] || printf '%s\n' "$AHL_RESULTS_HEADER" > "$TSV"

peak_gb() { awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f",(t-a)/1048576}' /proc/meminfo; }

crash_forensics() {  # <bundle> <level>: snapshot the engine BEFORE anyone tears it down.
  # The host-process analogue of bench.sh's `docker logs -> vllm_crash.log`. A host engine's stdout
  # belongs to the operator's launcher, not to this script, so capture what /proc and the driver
  # still know: whether the pid is alive, what state it is in (D = stuck in a driver ioctl,
  # R = spinning), and the GB10 wedge signature from the lab notes / vLLM #43885 (~96% util at
  # 15-30 W, against 33-44 W healthy). This is the artefact that turns a wedge into evidence.
  local bundle="$1" level="${2:-?}" f="$1/engine_crash.log"
  {
    echo "== $ENGINE wedge @ c$level — $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
    echo "pid=$SRV_PID alive=$([ -d "/proc/$SRV_PID" ] && echo yes || echo no)"
    echo "cmdline: $SRV_CMD"
    echo "-- /proc/$SRV_PID/status --"
    sed -n '1,12p' "/proc/$SRV_PID/status" 2>/dev/null || echo "(pid gone)"
    echo "-- nvidia-smi --"
    nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu,clocks.sm --format=csv 2>&1 \
      || echo "(nvidia-smi unavailable)"
    echo "-- tail of level_c$level.log --"
    tail -n 40 "$bundle/level_c$level.log" 2>/dev/null || echo "(no level log)"
  } >"$f" 2>&1
  echo "   saved engine forensics -> $f" >&2
}

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

  # Effective knob set for THIS row: contract-order base knobs, then the llama.cpp launcher's own.
  # stall=na — a host process has no docker-log watchdog, so bench.sh's STALL_SECS has no analogue.
  # A list value is `|`-joined so no value can contain the `,` that separates knob pairs.
  knobs="levels=$(printf '%s' "${LEVELS_SET:-1,16}" | tr ',' '|'),max_s=$MAX_SECONDS,seed=$SEED,prompt=$prompt,output=$output"
  knobs+=",temp=$TEMP,stall=na,ltimeout=$LEVEL_TIMEOUT,gllm=${GLLM_VER:-na}"
  knobs+=",quant=$QUANT,np=${NP:-na},ctx=${SRV_CTX:-na},ctx_per_slot=$SRV_CTX_PER_SLOT"
  knobs+=",ngl=${SRV_NGL:-na},fa=${SRV_FA:-na},spec=${SRV_SPEC:-off},draft=${SRV_DRAFT:-na},think=$SRV_THINK"
  knobs+=",lcpp_env=${SRV_ENV:-none}"

  echo "== llamacpp $TAG: $shape (p$prompt/o$output) @ c${LEVELS[*]} (max_s=$MAX_SECONDS, seed=$SEED, temp=$TEMP) ==" >&2
  echo "   gguf: $QUANT${NP:+  np=$NP}" >&2
  tps=(na na na na na); status="measured"; peak=0; crash_level=""
  ran_levels=()                      # the levels actually ATTEMPTED — the validity input
  for level in "${LEVELS[@]}"; do
    idx="$(col_index "$level")"; [ "$idx" -ge 0 ] || continue
    if run_level "$bundle" "$level" "$data"; then
      tps[idx]="$TPS_OUT"
      ran_levels+=("$level")
      echo "   c$level = $TPS_OUT tok/s" >&2
    else
      tps[idx]="hang"; status="crash"; crash_level="$level"
      ran_levels+=("$level")   # a hung level WAS run: its missing json is itself a verdict
      echo "   c$level = CRASH/hang (see $bundle/level_c$level.log)" >&2
      break
    fi
    p="$(peak_gb)"; awk -v a="$p" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$p"
  done

  # Validity: rules live in the library. We consume its verdict + status floor and classify nothing.
  set +e
  v_out="$(ahl_validity "$bundle" "$(IFS=,; echo "${ran_levels[*]-}")" \
             "${tps[0]},${tps[1]},${tps[2]},${tps[3]},${tps[4]}" \
             --node-profile "$REPO_ROOT/results/$NODE_FP/node_profile.json")"
  v_rc=$?
  set -e
  IFS=$'\t' read -r validity req_counts floor <<< "$v_out" || true
  : "${validity:=na}"; : "${req_counts:=na}"; : "${floor:=na}"   # a column value is never empty
  if [ "$v_rc" -ne 0 ]; then                    # the library itself failed: no verdict was reached,
    floor="void"                                # so the row cannot be cited either way
    echo "   !! validity library failed (rc=$v_rc) — row recorded as void" >&2
  fi
  case "$floor" in
    ok)           ;;
    suspect|void) [ "$status" = crash ] || status="$floor" ;;
    *)            [ "$status" = crash ] || status="void" ;;   # unknown floor: refuse to cite
  esac
  if [ "$status" = crash ]; then rc_all=3                        # the box broke: outranks validity
  elif [ "$floor" != ok ] && [ "$rc_all" -eq 0 ]; then rc_all=4  # numbers are not citable
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$COMMIT" "$NODE_FP" "$ORG/$NAME" "$shape_tag" "$BACKEND" "$CONFIG_HASH" "$SCRIPT_REL" \
    "na" "$MAX_SECONDS" "$SEED" "${tps[0]}" "${tps[1]}" "${tps[2]}" "${tps[3]}" "${tps[4]}" \
    "$peak" "$req_counts" "$validity" "$knobs" \
    "$status" "cfg=$TAG quant=$QUANT${NP:+ np=$NP} temp=$TEMP${crash_level:+ hang@c$crash_level}${NOTES:+ $NOTES}" "$data_rel" >> "$TSV"
  echo "row appended: $TSV ($run_id, $status, validity=$validity, req=$req_counts)" >&2

  # ── Crash: stop the sweep here (contract §5; bench.sh:236-244 does the same across shapes) ──
  # Without this the next shape would be benched against the just-wedged engine and its row would
  # be written `status=measured validity=ok` — a citable number produced after the box broke. On
  # this node that is not a corner case: the lab notes record 10 wedge events across four vLLM
  # versions, firing at concurrency 1 as readily as at 32. Completed shapes and levels are kept.
  if [ "$status" = crash ]; then
    crash_forensics "$bundle" "$crash_level"
    # Teardown, host-process edition. bench.sh runs `adapter down` because IT owns the container it
    # benched; this bencher does NOT own the engine. The operator started it from launchers/, it is
    # often the box's serving process (`homelab up` puts ds4 on :8000), and a restart costs minutes
    # of GGUF I/O. The evidence is also weaker than bench.sh's: there is no log watchdog here, so a
    # guidellm/uv failure or a LEVEL_TIMEOUT trip reaches this branch with a HEALTHY server behind
    # it. So the default is deliberate, not an omission: preserve forensics, tell the operator
    # exactly what to do, and leave the process alone. AHL_KILL_ON_CRASH=1 opts an unattended run
    # into releasing the GPU itself.
    if [ ! -d "/proc/$SRV_PID" ]; then
      echo "   $ENGINE (pid $SRV_PID) is already gone — nothing to tear down" >&2
    elif [ "${AHL_KILL_ON_CRASH:-0}" = 1 ]; then
      echo "   AHL_KILL_ON_CRASH=1 — stopping $ENGINE (pid $SRV_PID) to release the GPU" >&2
      kill "$SRV_PID" 2>/dev/null || true
      for _ in $(seq 1 "${AHL_KILL_WAIT:-15}"); do [ -d "/proc/$SRV_PID" ] || break; sleep 1; done
      if [ -d "/proc/$SRV_PID" ]; then
        echo "   pid $SRV_PID survived SIGTERM — sending SIGKILL" >&2
        kill -9 "$SRV_PID" 2>/dev/null || true
      fi
      echo "   $ENGINE stopped — relaunch it from launchers/ before the next bench" >&2
    else
      echo "   !! $ENGINE (pid $SRV_PID) LEFT RUNNING — it may be wedged and holding the GPU." >&2
      echo "      Read $bundle/engine_crash.log, then 'kill $SRV_PID' and relaunch from launchers/." >&2
      echo "      AHL_KILL_ON_CRASH=1 makes an unattended run do that teardown automatically." >&2
    fi
    echo "stopping remaining shapes — engine wedged at c$crash_level (completed rows are kept)" >&2
    break
  fi
done
exit "$rc_all"
