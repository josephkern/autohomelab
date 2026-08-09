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

stop_prior() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "stopping llama-server (pid $(cat "$PIDFILE"))"
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  local stray
  stray="$(pgrep -f "llama-server .*--port ${PORT}( |\$)" 2>/dev/null || true)"
  if [ -n "$stray" ]; then
    echo "stopping stray llama-server on :${PORT} (pid ${stray})"
    kill ${stray} 2>/dev/null || true
  fi
  [ -n "$stray" ] && sleep 2 || true
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
nohup "$LCPP_BIN" \
  -m "$QUANT" -a "$ALIAS" \
  --host "$HOST" --port "$PORT" \
  -c "$CTX" -np "$NP" -ngl "$NGL" -fa "$FA" \
  --jinja --reasoning-format deepseek \
  "${SPEC_ARGS[@]}" "${THINK_ARGS[@]}" \
  > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
disown || true

echo "  pid $(cat "$PIDFILE")   |   log: $LOG"
echo "  OpenAI API: http://${HOST}:${PORT}/v1   (served model id: ${ALIAS})"
echo "  follow:  tail -f $LOG"
echo "  stop:    $0 stop"
