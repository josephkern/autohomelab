#!/usr/bin/env bash
# TUNED VARIANT (moe-marlin-024) — base: runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh
# Deltas vs base: --moe-backend flashinfer_cutlass -> marlin
# Hypothesis: marlin NVFP4-MoE serve_fail'd on 0.23 ("won't init on sm_121", 20260614_moe-marlin).
#   An external report (unverified Twitter post, 2026-07-12) claims marlin MoE serves on a DGX Spark
#   with vLLM 0.24 and dramatically improves MTP draft acceptance. This is the 30s SERVE-PROBE retest
#   on 0.24: does the kernel init at all? If it serves: full candidate (N=3 c1/c16 + mmlu reference —
#   MoE backend is quality-sensitive per moe-auto -1.3% on 0.24).

MODEL="RedHatAI/Qwen3.6-35B-A3B-NVFP4"
MODEL_REVISION="e850c696e6d75f965367e816c16bc7dacd955ffa"   # pinned for reproducibility
SERVED_NAME="qwen3.6-35b-a3b-nvfp4"

# Pinned backend image — v0.24.0 (backends/vllm/image.lock catalog).
VLLM_IMAGE="vllm/vllm-openai@sha256:251eba5cc7c12fed0b75da22a9240e582b1c9e39f6fbc064f86781b963bd814f"
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
  --moe-backend marlin
  --speculative-config '{"method":"mtp","num_speculative_tokens":2}'
  --enable-prefix-caching
  # --- functional (serving features; smoke.sh validates) ---
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"presence_penalty":1.5}'
)
# Optional env passed into the container.
VLLM_ENV=()
