#!/usr/bin/env bash
# run-queue-unsloth-qwen38-ctx.sh — context-length cost study for the PROMOTED unsloth final.
#
# The promoted _final serves --max-model-len 8192 against a 262144-native model. This measures what
# raising it costs on the tuning objective, and captures the KV-pool size needed to compute the
# long-context concurrency ceiling (which a 512/256 benchmark CANNOT show).
#
# Entry 1 re-measures the promoted final IN THIS SESSION — the finalize figure (206.50) was taken
# 20260818 and cross-session c16 drift on this node has exceeded the 3% rule before.
#
# Records for each config: median c16/c1 AND the engine's "GPU KV cache size" line.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RB=runbooks/unsloth/Qwen3.8-27B-NVFP4
OUT="${1:-research/CTX-unsloth-qwen38-27b-nvfp4.md}"
LOGD="${AHL_CTX_LOGDIR:-/tmp}"

CANDIDATES=(
  "$RB/VLLM-27-unsloth_Qwen3.8-27B_NVFP4_final.sh|8192 (promoted final — IN-SESSION REFERENCE)"
  "$RB/20260819_ctx65536_tuned.sh|65536"
  "$RB/20260819_ctx262144_tuned.sh|262144 (model native)"
)

{ echo "# Context-length cost — unsloth/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1 (MTP n=3)"; echo
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ) · N=3 · chat(512/256) · levels=1,16"
  echo; echo "| max-model-len | c16 med | c1 med | status | GPU KV cache tokens |"
  echo "|---|---|---|---|---|"; } > "$OUT"

for entry in "${CANDIDATES[@]}"; do
  rb="${entry%%|*}"; ctx="${entry##*|}"
  echo ">>> $(date -u +%H:%M:%SZ)  max-model-len $ctx" >&2
  # Serve first so we can capture the KV line, then let run_experiment reuse the healthy endpoint.
  scripts/serve.sh "$rb" >/dev/null 2>&1
  KV=$(docker logs ahl-vllm 2>&1 | grep -oE 'GPU KV cache size: [0-9,]+ tokens' | tail -1 | grep -oE '[0-9,]+' | tail -1)
  KV="${KV:-unknown}"
  echo ">>> KV cache tokens: $KV" >&2
  line="$(N=3 scripts/run_experiment.sh "$rb" 2>/dev/null | tail -1)"
  c16="$(sed -n 's/.*c16=\([^ ]*\).*/\1/p' <<<"$line")"
  c1="$(sed -n 's/.*c1=\([^ ]*\).*/\1/p' <<<"$line")"
  st="$(sed -n 's/.*status=\([^ ]*\).*/\1/p' <<<"$line")"
  echo "| $ctx | ${c16:-?} | ${c1:-?} | ${st:-?} | $KV |" >> "$OUT"
  echo ">>> $ctx: $line  (KV=$KV)" >&2
  scripts/serve.sh down >/dev/null 2>&1 || true
done

{ echo; echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo
  echo "A flat c16 means raising the limit is free for SHORT-context serving. It does NOT mean"
  echo "long-context serving is free: max concurrent full-length sequences = KV tokens / context used."; } >> "$OUT"
echo ">>> ctx study complete -> $OUT" >&2
