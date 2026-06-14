#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/baseline.sh on 2026-06-14.
# Result: Campaign winner by default: 6-candidate tune queue produced no >3% c16 gain over the migrated baseline. Baseline config (flashinfer_cutlass MoE + fp8 KV + MTP n=1) is optimal. c16=344.6; mmlu=78.19.
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# baseline for RedHatAI/Qwen3.6-35B-A3B-NVFP4 (MoE, hybrid attention) — node gb10-1988a9714b4e.
# MIGRATED from old-homelab/bin/docker-vllm-RedHatAI-Qwen3.6-35B-A3B-NVFP4.sh (proven on vLLM 0.22.0)
# to vLLM 0.23.0, with model-specific kernel/functional flags KEPT and the co-resident/latency
# resource flags RESET for a SOLO THROUGHPUT benchmark:
#   - image v0.22.0 -> v0.23.0 (default digest).
#   - --max-num-seqs 2 REMOVED (latency cap for the dual-host stack; would throttle c16/c32).
#   - --gpu-memory-utilization 0.37 -> 0.5 (solo, not co-resident with the coder host).
#   - --max-model-len 262144 -> 8192 (benchmark shapes; native is 256K — raise for long-context runs).
#   - KEPT: compressed-tensors, fp8 KV, flashinfer_cutlass MoE, MTP speculative, chunked/prefix
#     caching, qwen3_coder tool parser, qwen3 reasoning parser, chat sampling (temp1/top_p.95/k20/pp1.5).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one change). Confirm functional flags vs the model card.

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
  --speculative-config '{"method":"mtp","num_speculative_tokens":1}'
  --enable-prefix-caching
  # --- functional (serving features; smoke.sh validates) ---
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"presence_penalty":1.5}'
)
# Optional env passed into the container.
VLLM_ENV=()
