#!/usr/bin/env bash
# TUNED VARIANT (mtp-off) on vLLM 0.23.0 — base: runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/baseline.sh
# Deltas vs base: REMOVE --speculative-config (disable MTP speculative decode)
# Hypothesis: At c16 the batch is already compute-bound; MTP verification competes with the larger batch and rejected drafts waste compute. Dropping it may raise batched throughput (costs c1 latency). Lossless (spec-decode is exact).

MODEL="RedHatAI/Qwen3.6-35B-A3B-NVFP4"
MODEL_REVISION="e850c696e6d75f965367e816c16bc7dacd955ffa"   # pinned for reproducibility
SERVED_NAME="qwen3.6-35b-a3b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance / resource (tuned by the loop; reset from co-resident for solo throughput) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  --max-num-batched-tokens 16384
  --enable-chunked-prefill
  # --- model-specific kernel path (migrated from the proven 0.22.0 script) ---
  --quantization compressed-tensors
  --kv-cache-dtype fp8_e4m3
  --moe-backend flashinfer_cutlass
  --enable-prefix-caching
  # --- functional (serving features; smoke.sh validates) ---
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"presence_penalty":1.5}'
)
# Optional env passed into the container.
VLLM_ENV=()
