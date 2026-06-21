#!/usr/bin/env bash
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against nvidia_Qwen3-Next-80B-A3B-Instruct-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4"
MODEL_REVISION="8fb2682f136cf94d932a498f18cb1e428832a912"   # pinned for reproducibility
SERVED_NAME="qwen3-next-80b-a3b-instruct-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
# Patched 0.23.0 image (one-line fix for vLLM #35031 qwen3_next MTP NVFP4 weight-shape bug — see
# backends/vllm/images/qwen3next-mtp-fix/Dockerfile). Byte-identical to stock 0.23.0 for the non-MTP
# baseline (the patched file is only loaded under --speculative-config qwen3_next_mtp); kept constant
# across baseline + the MTP variant so the only baseline→mtp delta is the spec-config.
VLLM_IMAGE="vllm-openai:0.23.0-qwen3nextmtp-fix"   # local build id sha256:628a16cc5a4a (base @sha256:6d8429e3)
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":0.7,"top_p":0.8,"top_k":20}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice --tool-call-parser hermes   # hermes JSON-in-XML tool format (confirmed in chat_template.jinja)
  # NON-thinking Instruct: no reasoning-parser (chat_template has no enable_thinking/<think>)
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
