#!/usr/bin/env bash
# TUNED VARIANT (gpumem-0p8) — base: runbooks/RedHatAI/Qwen3-Coder-Next-NVFP4/baseline.sh
# Deltas vs base: `--gpu-memory-utilization 0.5 -> 0.8` (more KV/batch headroom).
# Hypothesis: 45 GB weights leave only ~15 GB KV at 0.5; 0.8 frees ~52 GB KV → more concurrent
#   sequences. Likely ~NEUTRAL for the chat c16 objective (16×768-tok KV is tiny, already fits at
#   0.5) but should help coder/high-concurrency. candidate-queue #2. Unified pool: watch box stability.
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
  --gpu-memory-utilization 0.8   # DELTA: 0.5 -> 0.8 (more KV headroom; unified pool — watch stability)
  --max-model-len 8192
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"top_p":0.95,"top_k":40}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder   # qwen3_coder XML tool format (confirmed in chat_template.jinja)
  # NON-thinking coder model: no --reasoning-parser (chat_template has no enable_thinking; <think> defined but unused)
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
