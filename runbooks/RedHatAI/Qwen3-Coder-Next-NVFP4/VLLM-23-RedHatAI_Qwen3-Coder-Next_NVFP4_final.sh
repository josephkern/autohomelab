#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/RedHatAI/Qwen3-Coder-Next-NVFP4/baseline.sh on 2026-06-20.
# Result: Baseline winner (vLLM 0.23.0). All 3 gates: smoke 3/3; gsm8k=94.24/mmlu=81.79 FULL + mmlu_pro=70.07(limit-100); chat c16=220.1/c32=286.65, coder c16=133.91. Tune loop: 4 cands all discarded (ngram -34.6%, mnbt +1.1%, gpumem +0.2%, moe-trtllm serve_fail). MTP unavailable — NVFP4 conversion stripped the head. Bandwidth-bound MoE, auto kernels (GDN Triton/FLA + FLASHINFER_CUTLASS) already optimal.
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against RedHatAI_Qwen3-Coder-Next-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="RedHatAI/Qwen3-Coder-Next-NVFP4"
MODEL_REVISION="27a8f16f463b9a13c91c332c40cf93e09717347e"   # pinned for reproducibility
SERVED_NAME="qwen3-coder-next-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"top_p":0.95,"top_k":40}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder   # qwen3_coder XML tool format (confirmed in chat_template.jinja)
  # NON-thinking coder model: no --reasoning-parser (chat_template has no enable_thinking; <think> defined but unused)
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
