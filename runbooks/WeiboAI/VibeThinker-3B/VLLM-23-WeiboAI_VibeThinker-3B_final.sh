#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/WeiboAI/VibeThinker-3B/baseline.sh on 2026-06-17.
# Result: Baseline stands (compute-bound 3B; tune async-sched +0.1% / batched-32k -0.4%, both within noise). Gates: smoke 2/2; competition-math aime24=90.0/aime25=86.67 (temp1.0 Pass@1, reproduces the paper's frontier AIME); chat c16=485/c32=853 (scales, compute-bound), coder c16=304/c32=400. BF16, no quant; long-CoT eval needs GEN_TOKS 32768 + EVAL_TIMEOUT 1800 + aime (boxed) tasks.
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against WeiboAI_VibeThinker-3B_Model_Card.md; scripts/smoke.sh validates.
#
# Model: Qwen2ForCausalLM (Qwen2.5-3B base) — DENSE, BF16, no quant, 36 layers, native ctx 131072 (64K
#   trained). Long-CoT *math/reasoning* model (paper 2606.16140; AIME26 94.3). Emits **DeepSeek-R1-style
#   `<think>…</think>` then the answer, in `content`** (verified — closes the tag reliably; the card's
#   "no <think>" is wrong). Rec sampling temp1.0/top_p0.95/top_k-1 (all tasks). Tiny (5.8 GB), loads fast.
# NOTE — eval-vs-serve: the GATES were validated on the eval config (parser-less, max-model-len 40960, NO
#   tools): smoke 2/2, aime24=90.0/aime25=86.67, chat c16=485/c32=853. This SERVE config adds, for interactive
#   clients, full 128K context + Qwen tool-calling (hermes) — neither changes the BF16 weights' quality, and
#   short-shape throughput is independent of max-model-len. Quality gate = `math` suite (aime24,aime25, boxed
#   extraction) via the CHAT endpoint (THINK=off → apply_chat_template; GEN_TOKS 32768, EVAL_TIMEOUT 1800).

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
  --max-model-len 131072          # full native 128K (raised from the eval's 40960; KV is cheap on this 3B)
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":-1}'   # card-recommended (all tasks)
  --enable-auto-tool-choice --tool-call-parser hermes   # Qwen2.5 tool format — for agent/OpenAI clients (e.g. pi)
  # NO --reasoning-parser: the model emits DeepSeek-R1 <think></think> in `content`; clients parse it there
  #   (in pi: compat.thinkingFormat=qwen-chat-template). A server-side parser (deepseek_r1) returns EMPTY content
  #   when long reasoning doesn't close </think> within budget (verified) — so reasoning stays client-side.
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
