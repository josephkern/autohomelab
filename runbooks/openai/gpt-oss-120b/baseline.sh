#!/usr/bin/env bash
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against openai_gpt-oss-120b_Model_Card.md; scripts/smoke.sh validates.

MODEL="openai/gpt-oss-120b"
MODEL_REVISION="b5c939de8f754692c1647ca79fbf85e8c1e70f8a"   # pinned for reproducibility
SERVED_NAME="gpt-oss-120b"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.85      # ~61GB MXFP4 weights on the 121.6GB unified pool won't fit at 0.50
                                     # (cf. Nemotron 75GB->0.85); leaves ample KV headroom at maxlen 8192
  --max-model-len 8192               # covers chat(512/256) + coder(4096/1024); native ctx is 131072 (yarn x32)
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  # MXFP4 experts auto-detected (quant_method=mxfp4 -> gpt_oss_mxfp4); attn/router/embed/lm_head stay BF16.
  # gpt-oss uses native Harmony output parsing; vLLM auto-sets reasoning_parser=openai_gptoss (set explicit).
  --reasoning-parser openai_gptoss
  --enable-auto-tool-choice --tool-call-parser openai   # gpt-oss tool parser registered name is "openai"
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
