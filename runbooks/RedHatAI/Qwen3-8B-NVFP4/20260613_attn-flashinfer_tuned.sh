#!/usr/bin/env bash
# TUNED VARIANT (attn-flashinfer) — base: runbooks/RedHatAI/Qwen3-8B-NVFP4/20260613_native-fp4_tuned.sh
# Deltas vs base: + `--attention-backend FLASHINFER` (base used auto -> FLASH_ATTN w/ bf16 KV).
# Hypothesis: FlashInfer is often faster than FlashAttention on Blackwell, so c16 may rise. Also a
#   DIAGNOSTIC: if FLASHINFER + bf16 KV wedges at c16 too, then exp#2's fp8-KV crash was the
#   attention backend (not the kv-dtype); if it runs clean, fp8-KV itself was the culprit.
# TUNED VARIANT (native-fp4) — base: runbooks/RedHatAI/Qwen3-8B-NVFP4/baseline.sh
# Deltas vs base: REMOVED `--linear-backend marlin` (+ its VLLM_MARLIN_USE_ATOMIC_ADD env) so vLLM
#   auto-selects the native NVFP4 W4A4 GEMM (FlashInferCutlass/Cutlass 12.0f on this CUDA-13 image).
# Hypothesis: native FP4 W4A4 uses FP4 tensor cores directly (vs Marlin's W4A16 weight-only
#   dequant→bf16), so it should raise c16 tok/s — IF it doesn't hit the sm_121 instability
#   (vllm #35519/#30163). The watchdog will catch a hang and log it as crash.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# This is the complete reproducible unit: pinned image + model + serving flags.
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh and documenting the delta in its header;
# keep this baseline unchanged.
#
# NVFP4-on-sm_121 notes (from source-level research; see docs/ + logbook):
#   - --quantization OMITTED on purpose: vLLM auto-detects compressed-tensors (W4A4 FP4).
#   - GEMM backend = Marlin (W4A16) for RELIABILITY: native FP4 (CUTLASS 12.0f) auto-select is
#     fast but fragile on GB10 (illegal-instruction crashes, vllm #35519/#30163). Marlin is the
#     unconditionally-supported, currently-fastest *reliable* path (~46-49 tok/s reported).
#     Tuning experiment #1 = drop --linear-backend to try native FP4.
#   - CUDA graphs kept ON: --enforce-eager triggers a known NVFP4 crash on GB10 (#35519).
#   - max-model-len 8192 bounds the KV pool (native 40960; at 40960 c32 KV alone OVERshoots the
#     unified pool — see scripts/kv_calc.py). 8192 covers the coder bench shape (max 8192).
#   - util 0.50: unified pool is shared with the OS; raise only if stable.

MODEL="RedHatAI/Qwen3-8B-NVFP4"
MODEL_REVISION="e391349c110709b87bfc2ad2fde3f50dc5839fd8"   # pinned for reproducibility
SERVED_NAME="qwen3-8b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
# Verified: this digest = v0.22.0, torch 2.11.0+cu130 (CUDA 13.0) — the fixed FP4 build.
VLLM_IMAGE="vllm/vllm-openai@sha256:0fec7ec5f3e6bc168e54899935fb0557da908a4832a1dbc88e2debcf2f889416"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  --enable-chunked-prefill
  --attention-backend FLASHINFER
)   # --linear-backend omitted -> auto-select native NVFP4 W4A4
VLLM_ENV=()
