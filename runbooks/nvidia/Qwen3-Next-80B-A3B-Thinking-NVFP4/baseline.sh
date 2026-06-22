#!/usr/bin/env bash
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against nvidia_Qwen3-Next-80B-A3B-Thinking-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4"
MODEL_REVISION="2adcdd3e2482cd6fa1676b4f8e6f459a28796f08"   # pinned for reproducibility
SERVED_NAME="qwen3-next-80b-a3b-thinking-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
# Patched 0.23.0 image (one-line fix for vLLM #35031 qwen3_next MTP NVFP4 weight-shape bug — see
# backends/vllm/images/qwen3next-mtp-fix/Dockerfile). Byte-identical to stock 0.23.0 for the non-MTP
# baseline (the patched file is only loaded under --speculative-config qwen3_next_mtp); kept constant
# across baseline + the MTP variant so the only baseline→mtp delta is the spec-config. MTP head is
# present in this build (`mtp.layers.0*` in the NVFP4 ignore-list — same as the Instruct NVFP4).
VLLM_IMAGE="vllm-openai:0.23.0-qwen3nextmtp-fix"   # local build id sha256:628a16cc5a4a (base @sha256:6d8429e3)
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":0.6,"top_p":0.95,"top_k":20}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice --tool-call-parser hermes   # hermes JSON-in-XML tool format (chat_template has tool support)
  --reasoning-parser qwen3   # THINKING model: chat_template ALWAYS opens <think> (line 85; NO enable_thinking gate) → route CoT to reasoning_content
  # NOTE (Gate-2 eval): pure always-on reasoner (no enable_thinking switch) → AHL_THINK_OFF is INERT here.
  #   Eval generative gsm8k/mmlu_pro thinking-ON with large GEN_TOKS + long EVAL_TIMEOUT (cf. VibeThinker long-CoT path).
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
