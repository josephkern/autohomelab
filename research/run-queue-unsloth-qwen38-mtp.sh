#!/usr/bin/env bash
# run-queue-unsloth-qwen38-mtp.sh — program.md §2 tune loop, wave 1 for unsloth/Qwen3.8-27B-NVFP4.
#
# MTP depth bracket around Inferact's n=3 optimum. Depth is re-derived, not inherited: Inferact's
# curve was NON-MONOTONE (n=1/n=2 ~151, n=3 168, n=4 158, n=5 151) and this checkpoint runs a
# different FP4 GEMM path, so both per-draft cost and acceptance can differ.
#
# Reference = the baseline measured THIS session (chat c16 136.36, suite 8cfcfcac, 20260818).
# KEEP if median c16 beats it by >3% (=> >140.5).
#
# If the winner lands at an EDGE of the bracket (n=2 or n=4), extend in that direction before
# moving on — that is how Inferact's true optimum was found past the published recipe value.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RB=runbooks/unsloth/Qwen3.8-27B-NVFP4
OUT="${1:-research/WAVE1-unsloth-qwen38-27b-nvfp4.md}"

CANDIDATES=(
  "$RB/20260818_mtp-n2_tuned.sh|MTP n=2"
  "$RB/20260818_mtp-n3_tuned.sh|MTP n=3 (Inferact's optimum)"
  "$RB/20260818_mtp-n4_tuned.sh|MTP n=4"
)

{
  echo "# Wave 1 (MTP depth) — unsloth/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1"
  echo
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ) · N=3 · shape=chat(512/256) · levels=1,16"
  echo "Reference: baseline chat c16 **136.36** (same session). KEEP if >3% (>140.5)."
  echo "Context: promoted Inferact final = 171.12 chat c16, on the heavier checkpoint."
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

{ echo; echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo
  echo "Verdicts are NOT auto-applied. If the winner is at an edge (n=2 or n=4), extend the bracket."; } >> "$OUT"
echo ">>> wave 1 complete -> $OUT" >&2
