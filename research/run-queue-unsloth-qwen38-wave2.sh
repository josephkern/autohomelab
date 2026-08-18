#!/usr/bin/env bash
# run-queue-unsloth-qwen38-wave2.sh — program.md §2 tune loop, wave 2 for unsloth/Qwen3.8-27B-NVFP4.
# One change each, all off the wave-1 winner (MTP n=3, chat c16 median 208.86 measured 20260818).
#
# Reference: 208.86. KEEP if median c16 beats it by >3% (=> >215.1).
# NOTE the reference was measured TODAY, same session family as these runs. If the box is
# power-cycled before this queue runs, re-measure n=3 first (cross-session c16 drift on this node
# has exceeded the 3% rule before — AGENTS.md).
#
# Dropped from the original wave-2 shortlist: --compilation-config cudagraph_mode FULL_AND_PIECEWISE.
# It is ALREADY the 0.27.1 default — the unsloth baseline's engine config dump shows
# 'cudagraph_mode': <CUDAGraphMode.FULL_AND_PIECEWISE: (2,1)>. Testing it would have been a no-op.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RB=runbooks/unsloth/Qwen3.8-27B-NVFP4
OUT="${1:-research/WAVE2-unsloth-qwen38-27b-nvfp4.md}"

CANDIDATES=(
  "$RB/20260818_n3-schedtok8k_tuned.sh|--max-num-scheduled-tokens 8192 (the untested Inferact thread)"
  "$RB/20260818_n3-qwen35mtp_tuned.sh|arch-specific spec method qwen3_5_mtp vs generic mtp"
  "$RB/20260818_n3-dspark-n7_tuned.sh|DSpark drafter n=7 (NUMERIC-RISKY: needs its own Gate 2)"
)

{
  echo "# Wave 2 — unsloth/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1"
  echo
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ) · N=3 · shape=chat(512/256) · levels=1,16"
  echo "Reference: MTP n=3 chat c16 **208.86**. KEEP if >3% (>215.1)."
  echo
  echo "| candidate | c16 med | c1 med | status | note |"
  echo "|---|---|---|---|---|"
} > "$OUT"

for entry in "${CANDIDATES[@]}"; do
  rb="${entry%%|*}"; note="${entry##*|}"
  echo ">>> $(date -u +%H:%M:%SZ)  $(basename "$rb") — $note" >&2
  line="$(N=3 scripts/run_experiment.sh "$rb" 2>/dev/null | tail -1)"
  c16="$(sed -n 's/.*c16=\([^ ]*\).*/\1/p' <<<"$line")"
  c1="$(sed -n 's/.*c1=\([^ ]*\).*/\1/p' <<<"$line")"
  st="$(sed -n 's/.*status=\([^ ]*\).*/\1/p' <<<"$line")"
  echo "| \`$(basename "$rb")\` | ${c16:-?} | ${c1:-?} | ${st:-?} | $note |" >> "$OUT"
  echo ">>> $(basename "$rb"): $line" >&2
  scripts/serve.sh down >/dev/null 2>&1 || true
done

{ echo; echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo
  echo "Verdicts NOT auto-applied. A crashed row writes a BOGUS tok/s (few requests returning"
  echo "instantly against a dead endpoint inflate successful.mean) — always check status before"
  echo "reading a number, and mark crashed rows status=crash / tps_c16=na."; } >> "$OUT"
echo ">>> wave 2 complete -> $OUT" >&2
