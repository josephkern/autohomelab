#!/usr/bin/env bash
# TUNED VARIANT (batched-32k) — base: runbooks/WeiboAI/VibeThinker-3B/baseline.sh
# Deltas vs base: + `--max-num-batched-tokens 32768`.
# Hypothesis: larger token budget per step → fuller GPU batches at c16/c32 on a compute-bound 3B
#   (default cap can leave the GPU under-fed when many short decodes coexist with prefills).
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against WeiboAI_VibeThinker-3B_Model_Card.md; scripts/smoke.sh validates.
#
# Model: Qwen2ForCausalLM (Qwen2.5-3B base) — DENSE, BF16, no quant, 36 layers, native ctx 131072 (64K
#   trained). Long-CoT *math/reasoning* model (paper 2606.16140; AIME26 94.3): emits raw chain-of-thought
#   directly in `content` with **NO `<think>` tags** → NO --reasoning-parser, NO thinking-toggle. Not agentic
#   → NO tool parser. Rec sampling temp1.0/top_p0.95/top_k-1 (all tasks). Tiny (5.8 GB) → loads fast, fits easily.
#   --max-model-len 40960: large to fit the competition-math eval's long CoT (eval.sh `math` suite, GEN_TOKS
#   32768); throughput shapes (chat 512/256, coder 4096/1024) are unaffected. Quality gate = `math` suite
#   (minerva_math500,aime25) run via the CHAT endpoint (THINK=off → apply_chat_template; it's chat-tuned).

MODEL="WeiboAI/VibeThinker-3B"
MODEL_REVISION="0c7115fdd0957b3da0f2a0829ab1763969d30300"   # pinned to the CACHED revision (local weights; HF main moved to 51e5928)
SERVED_NAME="vibethinker-3b"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 40960           # large: fits the math eval's long CoT (GEN_TOKS 32768); short shapes unaffected
  --max-num-batched-tokens 32768  # DELTA: larger per-step token budget
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":-1}'   # card-recommended (all tasks)
  # NO --reasoning-parser: raw CoT in content, no <think> tags. NO tool parser: not agentic.
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
