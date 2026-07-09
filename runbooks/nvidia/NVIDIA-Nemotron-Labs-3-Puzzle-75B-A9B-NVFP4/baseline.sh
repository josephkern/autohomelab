#!/usr/bin/env bash
# BASELINE — first green serve for the standard suite. Derived from the node profile +
# the model card's recommended (non-MTP) vLLM serve recipe, adapted to single-GPU (TP=1).
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against nvidia_NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4_Model_Card.md; scripts/smoke.sh validates.
#
# Model: NemotronHPuzzleForCausalLM (model_type nemotron_h_puzzle) — NAS-"Puzzle"-compressed
#   hybrid: interleaved Mamba2 + latent-MoE (512 routed + 1 shared expert) + Attention, 88 layers,
#   9B active / 75B total, native 262K context. ModelOpt MIXED_PRECISION quant: routed experts NVFP4
#   (W4, group_size 16), Mamba/shared-expert projections FP8. Reasoning + tool-calling; native MTP
#   (num_nextn_predict_layers=1). vLLM 0.24.0 registers the arch (-> nemotron_h module) + nemotron_v3
#   reasoning parser + nemotron_h_mtp spec method natively (verified in-image). 53.5 GB download.
#
# Baseline design (vendor non-MTP recipe, minus project tune-levers):
#   - gpu-memory-utilization 0.85 (NOT the unified 0.50 default): 53.5 GB weights = 0.44 of the
#     121.6 GiB pool; 0.50 (~60 GB) barely fits weights with no KV room. 0.85 (~103 GB) leaves
#     ~50 GB for hybrid KV + mamba state + headroom. Kept as a tune dimension.
#   - Mamba correctness set kept in baseline (vendor-recommended for this fp16-mamba-cache NVFP4
#     hybrid; NOT speculative perf): --mamba-backend flashinfer, --mamba-ssm-cache-dtype float16 +
#     stochastic rounding (philox 5) to preserve accuracy at fp16 cache. --trust-remote-code for
#     the Puzzle heterogeneous per-layer config.
#   - DEFERRED to the tune loop (card includes them; project treats as levers): --speculative-config
#     (MTP, the expected dominant lever), --async-scheduling, --enable-expert-parallel (multi-GPU;
#     card TP=2/4 — inert/no-op on our TP=1), --moe-backend, --kv-cache-dtype, ablating mamba flags.

MODEL="nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4"
MODEL_REVISION="1d370e47fbc56d1019a471c2339663cdbbb5236f"   # pinned for reproducibility
SERVED_NAME="nvidia-nemotron-labs-3-puzzle-75b-a9b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:251eba5cc7c12fed0b75da22a9240e582b1c9e39f6fbc064f86781b963bd814f"  # v0.24.0
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.85   # 53.5 GB weights on the 121.6 GiB unified pool (see header)
  --max-model-len 131072          # 128K (native 262K); benchmark shapes need <=5120
  # --- functional / arch-correctness (vendor-recommended for this hybrid NVFP4 model; smoke.sh validates) ---
  --trust-remote-code                          # Puzzle NAS heterogeneous per-layer config
  --mamba-backend flashinfer                   # hybrid-Mamba2 backend (card-recommended)
  --mamba-ssm-cache-dtype float16              # card-recommended mamba SSM cache dtype ...
  --enable-mamba-cache-stochastic-rounding     # ... with stochastic rounding to hold accuracy at fp16
  --mamba-cache-philox-rounds 5
  --override-generation-config '{"temperature":1.0,"top_p":0.95}'   # model-recommended sampling
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser nemotron_v3
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()

# Eval overlay — thinking-OFF generative eval (suite.sh / AHL_THINK_OFF=1). This model has a real
# enable_thinking switch (default {"enable_thinking": false}), unlike Nemotron-3-Super which needed
# {"low_effort": true} to avoid zero-token output from a pre-closed <think></think>. PROBE think-off
# content non-empty at baseline before trusting generative scores; switch to low_effort if empty.
AHL_THINK_OFF_KWARGS='{"enable_thinking": false}'
