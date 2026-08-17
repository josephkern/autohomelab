#!/usr/bin/env bash
# run-queue-qwen38-wave3.sh — wave 3 for Inferact/Qwen3.8-27B-NVFP4 on vLLM 0.27.1.
#
# Runs each candidate as one experiment (serve once, bench N=3, tear down) and prints the
# median line from run_experiment.sh. Sequential by design: one GPU, and the charter requires a
# quiesced box for comparable numbers.
#
# ORDER MATTERS. Entry 1 re-measures the CURRENT BEST (mtp n=3) in THIS session. The box was
# power-cycled between wave 2 and wave 3, and AGENTS.md records cross-session c16 drift of 10.7%
# on an identical config (FF711) — larger than the 3% KEEP rule. So the 20260816 figure of 167.66
# is NOT a valid comparator today; every wave-3 verdict is taken against the in-session reference
# this run produces.
#
#   scripts/run_experiment.sh prints:  MEDIAN c16=<x> c1=<y> n=<k> status=<ok|crash|...>
#
# Usage:  research/run-queue-qwen38-wave3.sh [outfile]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RB=runbooks/Inferact/Qwen3.8-27B-NVFP4
OUT="${1:-research/WAVE3-qwen38-27b-nvfp4.md}"

CANDIDATES=(
  "$RB/20260816_mtp-n3_tuned.sh|REFERENCE re-measure (current best, in-session)"
  "$RB/20260817_n3-qwen35mtp_tuned.sh|arch-specific spec method qwen3_5_mtp (vs generic mtp)"
  "$RB/20260817_n3-cudagraph-full_tuned.sh|cudagraph_mode FULL_AND_PIECEWISE (vs PIECEWISE)"
  "$RB/20260817_n3-dspark-n7_tuned.sh|DSpark drafter n=7 probabilistic (NUMERIC-RISKY)"
)

{
  echo "# Wave 3 — Inferact/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1"
  echo
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ) · N=3 · shape=chat(512/256) · levels=1,16"
  echo "Objective: median c16. KEEP if >3% over the IN-SESSION reference (entry 1)."
  echo
  echo "| candidate | c16 med | c1 med | status | note |"
  echo "|---|---|---|---|---|"
} > "$OUT"

for entry in "${CANDIDATES[@]}"; do
  rb="${entry%%|*}"; note="${entry##*|}"
  echo ">>> $(date -u +%H:%M:%SZ)  $rb — $note" >&2
  line="$(N=3 scripts/run_experiment.sh "$rb" 2>/dev/null | tail -1)"
  c16="$(sed -n 's/.*c16=\([^ ]*\).*/\1/p' <<<"$line")"
  c1="$(sed -n 's/.*c1=\([^ ]*\).*/\1/p' <<<"$line")"
  st="$(sed -n 's/.*status=\([^ ]*\).*/\1/p' <<<"$line")"
  echo "| \`$(basename "$rb")\` | ${c16:-?} | ${c1:-?} | ${st:-?} | $note |" >> "$OUT"
  echo ">>> $(basename "$rb"): $line" >&2
  # A crash tears the container down; make sure nothing is left holding the GPU.
  scripts/serve.sh down >/dev/null 2>&1 || true
done

{
  echo
  echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Verdicts are NOT auto-applied — compare each row to the reference row and apply the KEEP"
  echo "rule by hand. The DSpark row additionally needs its own Gate 2 (non-greedy draft sampling)"
  echo "before it can be considered for promotion, per AGENTS.md."
} >> "$OUT"
echo ">>> wave 3 complete -> $OUT" >&2
