#!/usr/bin/bash
#
# Serve DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF with
# llama.cpp (ggml-org) on NVIDIA GB10 (Grace-Blackwell, sm_121). Authored directly (not produced
# by scripts/gen_launcher.sh); llama.cpp is a host-process backend, not a vLLM _final config.
#
# llama-server is a HOST process (no Docker), so this does NOT use backends/vllm adapter.sh /
# image.lock — same shape as the ds4 launcher. It serves the OpenAI-compatible API on
# http://${HOST}:${PORT}/v1 and runs DETACHED (logs to $LOG).
#
#   ./LCPP-DavidAU_Qwen3.6-27B-FF711_NEO-MAX-MTP.sh          # start (replaces any prior server on $PORT)
#   ./LCPP-DavidAU_Qwen3.6-27B-FF711_NEO-MAX-MTP.sh stop     # stop it
#   tail -f ~/.llamacpp/ff711-27b.log                        # follow load / serving logs
#   MTP=0 ./LCPP-….sh                       # disable multi-token prediction (the regular-vs-MTP A/B)
#   QUANT=~/gguf/<file>.gguf ./LCPP-….sh    # swap the quant (the campaign's primary axis)
#   NP=1 ./LCPP-….sh                        # single slot (c1-only latency runs)
#   THINK_OFF=1 ./LCPP-….sh                 # thinking-OFF serve for generative eval (AGENTS.md gate 2)
#
# The three gates run against this server via the shared stub (suite.sh can't drive it — that
# calls the vLLM serve.sh):
#   scripts/smoke.sh launchers/LCPP-…-MTP.smoke-runbook.sh
#   TOKENIZER=DavidAU/…-NM-DAU-MTP scripts/eval.sh launchers/LCPP-…-MTP.smoke-runbook.sh general
#   TAG=<slug> scripts/bench_llamacpp.sh launchers/LCPP-…-MTP.smoke-runbook.sh chat coder
#
# CAMPAIGN RESULT 20260809 (llamacpp@0865990) — THIS FILE IS THE PROMOTED ARTIFACT.
# The tune loop's winner IS this file's default config, so promotion changed nothing but the record.
# Baseline/winner: chat c16 63.51 / c1 19.09 (N=3 median); finalize sweep c1 18.88, c4 28.02,
# c8 36.05, c16 70.32. Gates: 1 PASS (4/4) · 2 PARTIAL (gsm8k 99.0 @LIMIT=100 think-off; mmlu_pro
# deferred) · 3 PASS chat (coder INVALID at MAX_SECONDS=180 — needs >=600; c32 uncharacterized).
# All five tune candidates discarded — but note ~10% cross-session c16 drift exceeds the +3% KEEP
# rule, so "not separable" is the honest verdict, not "worse". Full detail + the bandwidth analysis:
#   results/gb10-1988a9714b4e/DavidAU/Qwen3.6-27B-…-NEO-MAX-MTP-GGUF/logbook.md
#
#   MTP on/off (matched Q5_K_M pair):  c1 19.09 vs 12.03  -> MTP is worth +58.7% single-stream
#   MTP_DRAFT 1 / 2 / 3:               c1 16.61 / 19.09 / 20.01 ; c16 64.30 / 63.51 / 61.58
#   Q4_K_M / Q5_K_M / Q6_K (all MTP):  c1 20.10 / 19.09 / 16.89 ; c16 63.37 / 63.51 / 58.63
#
# LATENCY VARIANT (documented, not the default): for single-user interactive use — what this model
# actually does on OWUI — MTP_DRAFT=3 is the best measured c1 (20.01, +4.8%) at -3.0% c16. The
# charter tunes c16, so d2 stays default; set MTP_DRAFT=3 if latency matters more than batch.
#
# MODEL NOTES (from the model card + config.json of the bf16 source):
# - arch `qwen35` DENSE 27B, 64 layers, hybrid attention: `linear_attention` x3 then
#   `full_attention` every 4th layer. Only the 16 full-attention layers hold a growing KV cache
#   (~64 KiB/token total); the 48 linear layers carry a constant-size recurrent state per slot.
# - MTP: `mtp_num_hidden_layers: 1`. DavidAU embeds the MTP tensors IN these `-MTP-` GGUFs at
#   Q8_0 (no sidecar file), so `--spec-type draft-mtp` alone loads them — llama.cpp gates the
#   NextN tensors on that type (src/models/qwen35.cpp `mtp_flags`/`ml.load_mtp`). The `--mtp`
#   flag is DOWNLOAD-only (LLAMA_EXAMPLE_DOWNLOAD) and does nothing here.
# - Card: MTP acceptance ~60% at 2 draft tokens; "keep temp 1 or less (higher temps degrade MTP)".
#   Benchmarks pin temp 0 anyway (bench_llamacpp.sh TEMP=0), which is MTP's best case.
# - VL model (vision tower + mmproj-*.gguf in the repo) served TEXT-ONLY: no --mmproj, matching
#   our text suite and the unsloth Qwen3.6-27B vLLM runbook's `--limit-mm-per-prompt image:0`.
#
# One-time setup:
#   Build engine:  scripts/build_llamacpp.sh   (cmake -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121)
#   Weights:       DavidAU/…-NEO-MAX-MTP-GGUF on HF (ungated) -> ~/gguf
# llama.cpp and vLLM/ds4 CANNOT co-reside on the 128 GB GB10 — stop the other one first.
#
# HOST defaults to 0.0.0.0 so the OWUI container reaches it via host.docker.internal:${PORT}
# (OWUI's OpenAI connection already points at http://host.docker.internal:8000/v1).

set -euo pipefail

# ---- config (edit here) -----------------------------------------------------
LCPP_DIR="${LCPP_DIR:-$HOME/code/llama.cpp}"
LCPP_BIN="${LCPP_BIN:-$LCPP_DIR/build/bin/llama-server}"
Q="Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO"
QUANT="${QUANT:-$HOME/gguf/$Q-MTP-Q5_K_M.gguf}"   # campaign axis: IQ4_XS|Q4_K_M|Q5_K_M|Q6_K|Q8_0, MTP or regular
ALIAS="${ALIAS:-ff711-27b}"       # served model id; MUST match the stub's SERVED_NAME
MTP="${MTP:-1}"                   # 1 = --spec-type draft-mtp (needs an "-MTP-" quant); 0 = plain decode
MTP_DRAFT="${MTP_DRAFT:-2}"       # draft tokens per speculative cycle (card reports ~60% accept at 2)
NP="${NP:-16}"                    # server slots. MUST be >= the highest bench concurrency level,
                                  # else requests QUEUE and c16 measures the queue, not the engine.
CTX_PER_SLOT="${CTX_PER_SLOT:-12288}"   # covers coder(4096/1024) worst case (8192 prompt + 2048 out)
CTX="${CTX:-$(( CTX_PER_SLOT * NP ))}"  # llama.cpp -c is TOTAL context, split across slots
NGL="${NGL:-999}"                 # all layers on GPU
FA="${FA:-on}"                    # flash attention
THINK_OFF="${THINK_OFF:-}"        # 1 = serve with thinking disabled (generative eval path)
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
LOG="${LOG:-$HOME/.llamacpp/ff711-27b.log}"
PIDFILE="${PIDFILE:-$HOME/.llamacpp/ff711-27b.pid}"
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG")"

# Stop any prior server and WAIT for it to actually exit. A server with in-flight slots takes
# ~30s to cancel them and release :$PORT; a fixed short sleep here races the new process into a
# bind failure that looks like a silent startup hang (hit during the FF711 campaign). Poll instead,
# then escalate to SIGKILL rather than starting on a port that is still held.
stop_prior() {
  local pids=()
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && pids+=("$(cat "$PIDFILE")")
  local stray
  stray="$(pgrep -f "llama-server .*--port ${PORT}( |\$)" 2>/dev/null || true)"
  [ -n "$stray" ] && pids+=(${stray})
  [ "${#pids[@]}" -eq 0 ] && return 0

  # de-duplicate (pidfile and pgrep usually name the same process)
  mapfile -t pids < <(printf '%s\n' "${pids[@]}" | sort -u)
  echo "stopping prior llama-server (pid ${pids[*]}) — draining slots, this can take ~30s"
  kill "${pids[@]}" 2>/dev/null || true

  local waited=0
  while [ "$waited" -lt "${STOP_TIMEOUT:-90}" ]; do
    local alive=0
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    # the port must be free too — the socket outlives the process briefly
    if [ "$alive" -eq 0 ] && ! (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
      exec 3<&- 2>/dev/null || true
      echo "  prior server stopped after ${waited}s"
      return 0
    fi
    sleep 2; waited=$((waited + 2))
  done

  echo "  still up after ${waited}s — SIGKILL" >&2
  kill -9 "${pids[@]}" 2>/dev/null || true
  sleep 3
}

if [ "${1:-}" = "stop" ]; then
  stop_prior
  rm -f "$PIDFILE"
  echo "stopped."
  exit 0
fi

[ -x "$LCPP_BIN" ] || { echo "ERROR: llama-server not built at $LCPP_BIN — run: scripts/build_llamacpp.sh" >&2; exit 1; }
[ -f "$QUANT" ]    || { echo "ERROR: model GGUF not found: $QUANT" >&2; exit 1; }

SPEC_ARGS=()
if [ "$MTP" = 1 ]; then
  case "$(basename "$QUANT")" in
    *-MTP-*) ;;
    *) echo "ERROR: MTP=1 but $(basename "$QUANT") is not an \"-MTP-\" quant (no NextN tensors to load)." >&2
       echo "       Use an -MTP- file, or set MTP=0 for the regular-quant leg of the A/B." >&2; exit 1 ;;
  esac
  SPEC_ARGS=(--spec-type draft-mtp --spec-draft-n-max "$MTP_DRAFT")
fi

THINK_ARGS=()
[ -n "$THINK_OFF" ] && THINK_ARGS=(--chat-template-kwargs '{"enable_thinking": false}')

stop_prior

echo "starting llama-server: $(basename "$QUANT") on ${HOST}:${PORT}"
echo "  ctx=${CTX} (np=${NP} x ${CTX_PER_SLOT}/slot), ngl=${NGL}, fa=${FA}, MTP=${MTP}$([ "$MTP" = 1 ] && echo " draft=${MTP_DRAFT}")${THINK_OFF:+, thinking=OFF}"
# APPEND, never truncate: a departing server keeps its log fd open while it drains, so a
# truncating redirect leaves the old process writing at a stale offset (sparse file, interleaved
# nonsense). The separator keeps runs readable.
{ echo; echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) start: $(basename "$QUANT") np=$NP ctx=$CTX MTP=$MTP${THINK_OFF:+ think=off} ====="; } >> "$LOG"
nohup "$LCPP_BIN" \
  -m "$QUANT" -a "$ALIAS" \
  --host "$HOST" --port "$PORT" \
  -c "$CTX" -np "$NP" -ngl "$NGL" -fa "$FA" \
  --jinja --reasoning-format deepseek \
  "${SPEC_ARGS[@]}" "${THINK_ARGS[@]}" \
  >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"
disown || true

echo "  pid $(cat "$PIDFILE")   |   log: $LOG"
echo "  OpenAI API: http://${HOST}:${PORT}/v1   (served model id: ${ALIAS})"
echo "  follow:  tail -f $LOG"
echo "  stop:    $0 stop"
