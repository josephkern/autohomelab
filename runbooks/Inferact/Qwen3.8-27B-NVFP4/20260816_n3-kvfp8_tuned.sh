#!/usr/bin/env bash
# TUNED VARIANT (n3-kvfp8) — base: runbooks/Inferact/Qwen3.8-27B-NVFP4/20260816_mtp-n3_tuned.sh
# Deltas vs base: ADD --kv-cache-dtype fp8 (on top of the n=3 winner)
# Hypothesis: the Spark Arena GB10 recipe for this exact model ships --kv-cache-dtype fp8, so it is known
#   to at least serve on this silicon. Halving KV bytes should raise the batched objective by
#   letting more sequences stay resident. NOTE this arch already has tiny KV (only 16 of 64 layers
#   are full-attention; baseline showed 371,565 KV tokens = 45x concurrency at ctx 8192), so the
#   headroom may simply not be the binding constraint here -- KV pressure is NOT what limits c16.
#   NUMERIC-RISKY KNOB: unlike spec-decode (greedy-lossless), fp8 KV changes arithmetic, so this
#   one needs its OWN Gate 2 in the SAME session as a reference re-measure, per the charter.
#   Also watch the attention backend: on the 8B, changing KV dtype SWITCHED FA2 -> FlashInfer.
# TUNED VARIANT (mtp-n3) — base: runbooks/Inferact/Qwen3.8-27B-NVFP4/baseline.sh
# Deltas vs base: ADD --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
# Hypothesis: the value the Spark Arena GB10 recipe ships for this exact model
#   (spark-arena.com recipe 18733214, unsloth NVFP4 build, nvcr vllm 26.07). Deepest drafting wins
#   if acceptance holds up — but this arch has a SINGLE MTP layer re-run 3x, so acceptance should
#   decay fastest here. Testing it because the recipe is real GB10 evidence, NOT because we expect
#   it to win: Spark Arena is a PERF-ONLY leaderboard tuned for headline single-stream numbers,
#   with no quality gate and no c16 objective. Bracket member: n=1 vs n=2 vs n=3.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against Inferact_Qwen3.8-27B-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="Inferact/Qwen3.8-27B-NVFP4"
MODEL_REVISION="6128240ebaf4eaa7bad2b3d1c72c37d677c5f462"   # pinned for reproducibility
SERVED_NAME="qwen3.8-27b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"   # v0.27.1
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  --kv-cache-dtype fp8
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
  # --- functional (serving features; CONFIRMED against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20}'   # model-recommended THINKING-mode sampling (generation_config.json + card)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()

# Thinking-OFF kwargs for the Gate-2 generative eval serve (AGENTS.md → thinking-OFF generative eval).
# This model's chat template renders a PRE-CLOSED '<think>\n\n</think>\n\n' for enable_thinking=false —
# the same shape that made NemotronH emit zero tokens (gsm8k 0.0). PROBE the think-off serve before
# trusting generative scores; if `content` comes back empty, fall back to the model's own reduced-
# reasoning knob: AHL_THINK_OFF_KWARGS='{"reasoning_effort":"low"}'.
AHL_THINK_OFF_KWARGS='{"enable_thinking": false}'
