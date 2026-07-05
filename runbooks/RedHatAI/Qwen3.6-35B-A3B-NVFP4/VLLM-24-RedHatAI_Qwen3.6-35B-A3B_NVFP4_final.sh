#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/20260704_mtp-n2_tuned.sh on 2026-07-05.
# Result: 0.24.0 campaign winner: MTP num_speculative_tokens 1->2 = +5.9% c16 (357.4 vs 337.7 baseline, both-shape), lossless spec-decode (mmlu 82.65~=82.82, gsm8k 96~=98 noise, mmlu_pro 68.21==). 0.24's Model-Runner-V2 Qwen-MoE spec-decode migration unlocked n=2 (was only +2.8% sub-threshold on 0.23). All 3 gates green.
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# TUNED VARIANT (mtp-n2) — base: runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/20260704_v0.24.0_baseline.sh
# Deltas vs base: MTP num_speculative_tokens 1 -> 2
# Hypothesis: 0.24 migrated Qwen MoE spec-decode to Model-Runner-V2 — n=2 drafting may now scale
#   better under batching than on 0.23 (where n=2 was +2.8%, sub-threshold). Spec-decode = lossless.
# 0.24.0 RE-BASELINE — RedHatAI/Qwen3.6-35B-A3B-NVFP4 (MoE A3B + hybrid attn + MTP), node gb10-1988a9714b4e.
# Version-transition baseline for the vLLM 0.23.0 -> 0.24.0 campaign. This is the REFERENCE the 0.24
# candidate queue ablates against; it is the promoted VLLM-23 _final config with EXACTLY ONE change:
#
#   Delta vs base: VLLM_IMAGE v0.23.0 (sha256:6d8429e3) -> v0.24.0 (sha256:251eba5c)
#   Hypothesis:    0.24.0's SM120 MoE path + MRv2 Qwen-MoE spec-decode may move batched c16; at minimum
#                  this establishes the apples-to-apples 0.24 reference vs 0.23 (c16=344.6, mmlu=78.19).
#
# ALL functional/kernel flags HELD CONSTANT from the 0.23 _final: compressed-tensors, fp8 KV,
# flashinfer_cutlass MoE, MTP speculative n=1, chunked/prefix caching, qwen3_coder tool parser,
# qwen3 reasoning parser, chat sampling (temp1/top_p.95/k20/pp1.5). Solo-throughput resource flags
# (gpu-mem-util 0.5, max-model-len 8192, max-num-batched-tokens 16384) unchanged.

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
  --moe-backend flashinfer_cutlass
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
