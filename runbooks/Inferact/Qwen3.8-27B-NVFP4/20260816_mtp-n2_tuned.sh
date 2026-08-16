#!/usr/bin/env bash
# TUNED VARIANT (mtp-n2) — base: runbooks/Inferact/Qwen3.8-27B-NVFP4/baseline.sh
# Deltas vs base: ADD --speculative-config '{"method":"mtp","num_speculative_tokens":2}'
# Hypothesis: the checkpoint ships a native MTP head (nvfp4_experts_mtp.safetensors, 15 tensors,
#   left UNQUANTIZED by the ModelOpt exclude_modules) so spec-decode should load without the
#   checkpoint patch Qwen3-Next needed. Baseline c1=10.34 tok/s x 24.57 GB = 240 GB/s = ~88% of
#   this box's 273 GB/s peak, i.e. decode is bandwidth-bound with NO engine headroom — speculation
#   is the only lever that can raise c1, and it should also lift batched c16 (the objective).
#   n=2 first because it won our 35B campaign; the Spark Arena recipe claims n=3, and FF711 found
#   the depth optimum SHALLOWS as batch grows — so n=1/2/3 are bracketed as separate variants
#   rather than adopting the recipe's value on faith.
# vLLM MTP/draft is greedy-lossless, so the quality gate carries over from baseline (no Gate 2
#   needed for this knob alone) — but see the grammar-500 follow-up: MTP is the leg that triggers
#   the xgrammar x reasoning-parser interaction, so re-run the forced-tool_choice check here.
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
  --speculative-config '{"method":"mtp","num_speculative_tokens":2}'
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
