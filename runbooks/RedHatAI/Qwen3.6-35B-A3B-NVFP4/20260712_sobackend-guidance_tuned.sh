#!/usr/bin/env bash
# TUNED VARIANT (sobackend-guidance) — base: runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/20260712_v0.25.0_baseline.sh
# Deltas vs base: + --structured-outputs-config '{"backend":"guidance"}'
# Hypothesis: xgrammar FSM desyncs at the <think>->content boundary under MTP spec-decode
#   (isolation matrix 20260712: think+MTP+grammar = 500 on 0.24 / corrupted json_object on 0.25;
#   any one feature removed = clean). The guidance backend validates differently and may survive
#   the drafter crossing the boundary -> smoke structured check (response_format json_object,
#   temp 0) becomes the pass/fail gate. Functional fix, not perf: bench must stay ==.
# ORIGINAL 0.25 BASELINE HEADER:
# Delta vs base: VLLM_IMAGE v0.24.0 (sha256:251eba5c) -> v0.25.0 (sha256:fc56161e)
# Hypothesis: 0.25.0 ships #45739 (NVFP4 swizzled-scale zero-init "restored for Blackwell decode
#   throughput") — a direct decode-path change for our quant format — plus MoE MLP Triton fused
#   dequant (#44667). Image-only transition baseline per the 0.23→0.24 pattern: config-identical
#   to the VLLM-24 _final, compared against the SAME-DAY fresh 0.24 reference
#   (exp 20260712: c16=359.4 c1=55.18 n=3, drafter acceptance 68.0%).

MODEL="RedHatAI/Qwen3.6-35B-A3B-NVFP4"
MODEL_REVISION="e850c696e6d75f965367e816c16bc7dacd955ffa"   # pinned for reproducibility
SERVED_NAME="qwen3.6-35b-a3b-nvfp4"

# Pinned backend image — v0.25.0 (backends/vllm/image.lock catalog; not yet default).
VLLM_IMAGE="vllm/vllm-openai@sha256:fc56161ee42a011aeee78b65d0a81b6683c7d04402fd40503d14d4d6c98f07cb"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance / resource (reset from co-resident for solo throughput) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  --max-num-batched-tokens 16384
  --enable-chunked-prefill
  # --- model-specific kernel path (migrated from the proven 0.22.0 script) ---
  --quantization compressed-tensors
  --kv-cache-dtype fp8_e4m3
  --moe-backend flashinfer_cutlass
  --speculative-config '{"method":"mtp","num_speculative_tokens":2}'
  --structured-outputs-config '{"backend":"guidance"}'
  --enable-prefix-caching
  # --- functional (serving features; smoke.sh validates) ---
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"presence_penalty":1.5}'
)
# Optional env passed into the container.
VLLM_ENV=()
