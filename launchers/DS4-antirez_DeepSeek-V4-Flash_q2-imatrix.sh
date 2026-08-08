#!/usr/bin/bash
#
# Serve DeepSeek-V4-Flash (q2 imatrix) with antirez/ds4 "DwarfStar" on NVIDIA GB10
# (Grace-Blackwell, sm_121). Authored directly (not produced by scripts/gen_launcher.sh);
# ds4 is a host-process backend, not a generated vLLM _final config.
#
# ds4 is a HOST process (self-contained native CUDA inference engine), not a Docker
# container, so this does NOT use backends/vllm adapter.sh / image.lock. It serves the
# OpenAI-compatible API on http://${HOST}:${PORT}/v1 and runs DETACHED (logs to $LOG).
#
#   ./DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh          # start (replaces any prior ds4-server on $PORT)
#   ./DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh stop     # stop it
#   tail -f ~/.ds4/deepseek-v4-flash.log                   # follow startup / serving logs
#   PORT=8001 ./DS4-….sh                                   # override the bind port
#   MTP=~/gguf/DeepSeek-V4-Flash-MTP-Q4K-Q8_0-F32.gguf ./DS4-….sh   # legacy one-stage MTP (bench: ~no gain on GB10)
#   DSPARK=1 ./DS4-….sh    # DSpark spec decode (greedy only; bench 20260721: DISCARD, −17% chat / −18% code)
#   BATCH=4 ./DS4-….sh     # --batched-session N (GB10 = ordered fallback; bench 20260721: no agg gain at c4,
#                          #  ~4 t/s per user, per-req latency worse — situational, default off)
#
# Campaign 20260721 (ds4@efdadd4, results/gb10-*/antirez/DeepSeek-V4-Flash/): baseline c1 median
# 17.96 tok/s greedy chat(512/256); DSpark + batched-session both discarded — this default
# (target-only, single-session) is the validated config.
# Campaign 20260808 (ds4@b030961, 2026-08-05 drop): engine-only update KEEP — c1 median 19.63
# (+9.3%), TTFT 2729→658 ms (native sm_121a + MMQ prefill tier + decode graphs). Config unchanged.
# DSpark/batched verdicts stand; Flash-0731 MXFP4 (~156 GB) does not fit GB10.
#
# One-time setup:
#   Build engine:  (cd ~/code/ds4 && make cuda-spark)        # antirez/ds4 canonical main
#   Weights:       antirez/deepseek-v4-gguf on HF (ungated)  # ~81 GiB q2 + 3.6 GiB MTP -> ~/gguf
# Needs ~85 GiB free unified memory; ds4 and vLLM CANNOT co-reside on the 128 GB GB10 —
# stop vLLM first:  docker stop vllm-qwen3-next-80b-a3b-instruct-nvfp4
#
# HOST defaults to 0.0.0.0 so the OWUI container reaches it via host.docker.internal:${PORT}
# (OWUI's OpenAI connection already points at http://host.docker.internal:8000/v1). Served
# model id: `deepseek-v4-flash`.

set -euo pipefail

# ---- config (edit here) -----------------------------------------------------
DS4_BIN="${DS4_BIN:-$HOME/code/ds4/ds4-server}"
MODEL="${MODEL:-$HOME/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf}"
MTP="${MTP:-}"                 # legacy one-stage MTP GGUF path (bench: ~no gain on GB10); superseded by DSPARK
DSPARK="${DSPARK:-}"           # 1 = DSpark spec decode (auto-uses DSPARK_GGUF via --mtp; greedy requests only)
DSPARK_GGUF="${DSPARK_GGUF:-$HOME/gguf/DeepSeek-V4-Flash-DSpark-support.gguf}"
BATCH="${BATCH:-}"             # N = --batched-session N resident KV sessions (size CTX*N to fit memory)
MTP_DRAFT="${MTP_DRAFT:-2}"    # draft tokens per speculative cycle (only used with legacy MTP)
CTX="${CTX:-32768}"           # allocated context tokens
HOST="${HOST:-0.0.0.0}"       # bind address; 0.0.0.0 so the OWUI container can reach it
PORT="${PORT:-8000}"          # OpenAI API port
LOG="${LOG:-$HOME/.ds4/deepseek-v4-flash.log}"
PIDFILE="${PIDFILE:-$HOME/.ds4/deepseek-v4-flash.pid}"
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG")"

stop_prior() {
  # stop via pidfile if valid, then sweep any stray ds4-server bound to this port
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "stopping ds4-server (pid $(cat "$PIDFILE"))"
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  local stray
  stray="$(pgrep -f "ds4-server .*--port ${PORT}( |\$)" 2>/dev/null || true)"
  if [ -n "$stray" ]; then
    echo "stopping stray ds4-server on :${PORT} (pid ${stray})"
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

[ -x "$DS4_BIN" ] || { echo "ERROR: ds4-server not built at $DS4_BIN — run: (cd ~/code/ds4 && make cuda-spark)" >&2; exit 1; }
[ -f "$MODEL" ]   || { echo "ERROR: model GGUF not found: $MODEL" >&2; exit 1; }

stop_prior

MTP_ARGS=()
if [ -n "$DSPARK" ]; then
  [ -n "$MTP" ] && { echo "ERROR: DSPARK and legacy MTP are mutually exclusive (both use --mtp)" >&2; exit 1; }
  [ -f "$DSPARK_GGUF" ] || { echo "ERROR: DSpark support GGUF not found: $DSPARK_GGUF" >&2; exit 1; }
  MTP_ARGS=(--mtp "$DSPARK_GGUF" --dspark)
elif [ -n "$MTP" ]; then
  [ -f "$MTP" ] || { echo "ERROR: MTP GGUF not found: $MTP" >&2; exit 1; }
  MTP_ARGS=(--mtp "$MTP" --mtp-draft "$MTP_DRAFT")
fi
BATCH_ARGS=()
[ -n "$BATCH" ] && BATCH_ARGS=(--batched-session "$BATCH")

echo "starting ds4-server: DeepSeek-V4-Flash on ${HOST}:${PORT} (ctx=${CTX}${DSPARK:+, DSpark=on}${MTP:+, MTP=on draft=$MTP_DRAFT}${BATCH:+, batched-session=$BATCH})"
nohup "$DS4_BIN" -m "$MODEL" --cuda --ctx "$CTX" --host "$HOST" --port "$PORT" --cors "${MTP_ARGS[@]}" "${BATCH_ARGS[@]}" > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
disown || true

echo "  pid $(cat "$PIDFILE")   |   log: $LOG"
echo "  OpenAI API: http://${HOST}:${PORT}/v1   (served model id: deepseek-v4-flash)"
echo "  follow:  tail -f $LOG"
echo "  stop:    $0 stop"
