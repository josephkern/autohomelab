#!/usr/bin/env bash
# run-queue-qwen38-wave3b.sh — wave 3b follow-on, run AFTER run-queue-qwen38-wave3.sh finishes.
#
# Added after reading the full 0xBakeer DGX-Spark writeup (same hardware: GB10, 273 GB/s, SM121,
# vLLM 0.27.1), which measured DSpark k=14 as 27% FASTER than k=7 on a single stream despite
# acceptance falling 98.7% -> 68.7%, because mean tokens per forward pass rose 7.91 -> 10.62.
# Wave 3 only brackets DSpark at k=7 (the value in the published serve config), so the depth axis
# is unexplored on our harness.
#
# NOTE: this is a separate script on purpose. Wave 3's queue was already executing, and bash reads
# a script incrementally by byte offset -- editing a running script corrupts it mid-run
# (AGENTS.md lab note).
#
# Usage:  research/run-queue-qwen38-wave3b.sh [outfile]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RB=runbooks/Inferact/Qwen3.8-27B-NVFP4
OUT="${1:-research/WAVE3B-qwen38-27b-nvfp4.md}"

CANDIDATES=(
  "$RB/20260817_n3-dspark-n14_tuned.sh|DSpark k=14 (depth axis; c1-optimal upstream, may invert at c16)"
)

{
  echo "# Wave 3b — Inferact/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1"
  echo
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ) · N=3 · shape=chat(512/256) · levels=1,16"
  echo "Compare against wave 3's IN-SESSION reference row, not the 20260816 figure."
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
  scripts/serve.sh down >/dev/null 2>&1 || true
done

echo >> "$OUT"; echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
echo ">>> wave 3b complete -> $OUT" >&2
