#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/RedHatAI/Qwen3-8B-NVFP4/20260613_kvfp8_tuned.sh on 2026-06-14.
# Result: 0.23.0 native NVFP4 W4A4 + fp8 KV (kv-cache-dtype fp8_e4m3) + reasoning-parser qwen3. ALL GATES: smoke 3/3; quality matched-L100 mmlu 73.25 (-0.36, 99.5% recovery)/gsm8k 92; throughput c16=563 (+11%) c32=950.6 (+23%) vs 0.23.0-native. full-eval absolute gsm8k=87.64/mmlu=70.99. vLLM 0.23.0 (img 6d8429e).
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# TUNED VARIANT (kvfp8) on vLLM 0.23.0 — base: runbooks/RedHatAI/Qwen3-8B-NVFP4/baseline.sh
# Deltas vs base: + --kv-cache-dtype fp8_e4m3 (re-test; crashed on 0.22.0)
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against RedHatAI_Qwen3-8B-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="RedHatAI/Qwen3-8B-NVFP4"
MODEL_REVISION="e391349c110709b87bfc2ad2fde3f50dc5839fd8"   # pinned for reproducibility
SERVED_NAME="qwen3-8b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  --kv-cache-dtype fp8_e4m3
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":0.6,"top_p":0.95,"top_k":20}'   # model-recommended sampling (generation_config.json)
  # --enable-auto-tool-choice --tool-call-parser hermes   # (Qwen3-8B tool support unconfirmed; leave off)
  --reasoning-parser qwen3   # Qwen3 emits <think>; route it to reasoning_content (confirmed via smoke)
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
