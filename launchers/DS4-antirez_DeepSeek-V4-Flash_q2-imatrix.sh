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
#   ./DS4-….sh             # DSpark is ON BY DEFAULT since round 4 (20260809): +7.0% c1, quality unchanged
#   DSPARK= ./DS4-….sh     # disable DSpark (target-only decode, the pre-round-4 default)
#   DSPARK=1 DSPARK_CONF=0.5 ./DS4-….sh   # sweep the confidence threshold (CUDA default 0.7)
#   DSPARK=1 DSPARK_STRICT=1 ./DS4-….sh   # target-only decode: reproducibility/quality control leg
#   BATCH=4 ./DS4-….sh     # --batched-session N (GB10 = ordered fallback; bench 20260721: no agg gain at c4,
#                          #  ~4 t/s per user, per-req latency worse — situational, default off)
#
# Campaign 20260721 (ds4@efdadd4, results/gb10-*/antirez/DeepSeek-V4-Flash/): baseline c1 median
# 17.96 tok/s greedy chat(512/256); DSpark + batched-session both discarded — this default
# (target-only, single-session) is the validated config.
# Campaign 20260808 (ds4@b030961, 2026-08-05 drop): engine-only update KEEP — c1 median 19.63
# (+9.3%), TTFT 2729→658 ms (native sm_121a + MMQ prefill tier + decode graphs). Config unchanged.
# DSpark/batched verdicts stood (carried forward, NOT re-measured); Flash-0731 MXFP4 (~156 GB) does
# not fit GB10.
# Campaign 20260809 ROUND 4 (ds4@84cc882): **DSpark PROMOTED, now the default.** Same-session
# target-only base c1 19.27 -> DSpark 20.61 (+7.0%); gsm8k strict 74.0 == 74.0 (matched pair, so the
# documented non-lossless divergence costs nothing here); smoke 3/3. The --dspark-strict control at
# +0.2% proves the gain is speculation, not load-path noise. Confidence axis is FLAT (0.0/0.3/0.7/
# 0.85 all 20.50-20.61) -> keep the 0.7 default. Round 1's -17% was measured at confidence 0.9 on
# engine efdadd4; at 0.85 on this engine the same setting gives +6.4%, so the ENGINE fixed it.
# Round 3b 20260808: 0731 q2 checkpoint refresh DISCARD — c1 flat (19.61) but gsm8k 76→60 strict /
# 99→82 flexible on matched pairs (likely longer thinking + truncation; see logbook). File kept in
# ~/gguf; this launcher stays on the pre-0731 GGUF.
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
# DSpark defaults ON since round 4, but it must YIELD to an explicit legacy MTP request: both paths
# use --mtp and the guard below hard-errors if each is set. Without this, `MTP=… ./DS4-….sh` (the
# documented legacy invocation) would fail the moment DSPARK gained a non-empty default.
# NOTE the `-` (not `:-`): ${DSPARK-1} defaults only when DSPARK is UNSET, so an explicitly empty
# `DSPARK= ./DS4-….sh` still disables. With `:-` an empty value would be replaced by the default and
# the documented disable invocation would silently turn DSpark ON.
if [ -n "$MTP" ]; then DSPARK="${DSPARK-}"; else DSPARK="${DSPARK-1}"; fi
                               # 1 = DSpark spec decode (auto-uses DSPARK_GGUF via --mtp; greedy requests only)
                               # DEFAULT ON since round 4 (20260809): +7.0% c1, gsm8k strict
                               # UNCHANGED (74.0 == 74.0 matched pair). Disable with `DSPARK= ./…sh`.
                               # CAVEAT: greedy-only — upstream "sampled decoding does not use DSpark
                               # proposals", so OWUI chat at temp>0 sees no speedup; the win is on
                               # agent/tool/structured (greedy) traffic. Costs a ~6 GB support GGUF.
DSPARK_GGUF="${DSPARK_GGUF:-$HOME/gguf/DeepSeek-V4-Flash-DSpark-support.gguf}"
DSPARK_CONF="${DSPARK_CONF:-}" # --dspark-confidence F (0..1): prunes draft suffixes unlikely to repay
                               # their verification cost. Engine default on CUDA is 0.7 (Metal 0.6);
                               # 0 forces fixed five-token blocks (diagnostics only). NOT a new flag —
                               # it already existed at the round-3 pin b030961 with the same 0.7
                               # default. Round 4 sweep (20260809, base 19.27): 0.5 -> 21.56 (+11.9%),
                               # 0.7 -> 20.61 (+7.0%), 0.85 -> 20.50 (+6.4%). Lower admits more drafts.
DSPARK_STRICT="${DSPARK_STRICT:-}"  # 1 = --dspark-strict: load DSpark but keep target-only decode.
                               # DSpark is NOT greedy-lossless (upstream README: a long greedy run may
                               # diverge from non-DSpark decode after a valid accepted block), so this
                               # is the reproducibility/quality control leg, not a perf config.
BATCH="${BATCH:-}"             # N = --batched-session N resident KV sessions (size CTX*N to fit memory)
MTP_DRAFT="${MTP_DRAFT:-2}"    # draft tokens per speculative cycle (only used with legacy MTP)
CTX="${CTX:-65536}"           # allocated context tokens (64K default 20260808 for pi/agent use:
                              # MLA KV is tiny — ~2 GiB context buffers at 64K; decode tapers
                              # ~18->14 t/s as ctx fills per upstream gb10.csv)
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
  # --dspark-confidence implies --dspark, but pass both so the log line is unambiguous about
  # which threshold produced a given results.tsv row (bench_ds4.sh hashes the served cmdline).
  MTP_ARGS=(--mtp "$DSPARK_GGUF" --dspark)
  [ -n "$DSPARK_CONF" ]   && MTP_ARGS+=(--dspark-confidence "$DSPARK_CONF")
  [ -n "$DSPARK_STRICT" ] && MTP_ARGS+=(--dspark-strict)
elif [ -n "$MTP" ]; then
  [ -f "$MTP" ] || { echo "ERROR: MTP GGUF not found: $MTP" >&2; exit 1; }
  MTP_ARGS=(--mtp "$MTP" --mtp-draft "$MTP_DRAFT")
fi
BATCH_ARGS=()
[ -n "$BATCH" ] && BATCH_ARGS=(--batched-session "$BATCH")

echo "starting ds4-server: DeepSeek-V4-Flash on ${HOST}:${PORT} (ctx=${CTX}${DSPARK:+, DSpark=on${DSPARK_CONF:+ conf=$DSPARK_CONF}${DSPARK_STRICT:+ STRICT/target-only}}${MTP:+, MTP=on draft=$MTP_DRAFT}${BATCH:+, batched-session=$BATCH})"
nohup "$DS4_BIN" -m "$MODEL" --cuda --ctx "$CTX" --host "$HOST" --port "$PORT" --cors "${MTP_ARGS[@]}" "${BATCH_ARGS[@]}" > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
disown || true

echo "  pid $(cat "$PIDFILE")   |   log: $LOG"
echo "  OpenAI API: http://${HOST}:${PORT}/v1   (served model id: deepseek-v4-flash)"
echo "  follow:  tail -f $LOG"
echo "  stop:    $0 stop"
