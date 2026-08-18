#!/usr/bin/env bash
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile.
# EDITED 20260818 per program.md §0.4 (confirm functional flags; pin the campaign image).
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
#
# WHY THIS CAMPAIGN EXISTS: this is the SAME BASE MODEL as the Inferact/Qwen3.8-27B-NVFP4
# campaign — Qwen/Qwen3.8-27B's config matches both checkpoints on every field (hidden 5120,
# 64 layers, vocab 248320, heads 24/4, head_dim 256, intermediate 17408, linear 16/48,
# full_attention_interval 4, mtp 1) — but a DIFFERENT NVFP4 quantization. Ours measures 25.5 GB
# of weights on disk; this one is ~19.9 GB of parameter bytes. Decode on this box is pinned at
# the memory-bandwidth wall (~255 GB/s of the GB10's 273 GB/s peak, reproduced independently by
# the FF711 llama.cpp campaign), so bytes-per-token maps almost directly to c1 tok/s. A ~22%
# lighter checkpoint is therefore a first-principles throughput lever, not a tuning guess.
#
# CONTROLLED COMPARISON: every flag below is IDENTICAL to
# runbooks/Inferact/Qwen3.8-27B-NVFP4/baseline.sh except MODEL and MODEL_REVISION, so the
# baseline delta isolates the checkpoint. Do not "improve" these flags here — tune from the
# baseline via the program.md loop, one change at a time.

MODEL="unsloth/Qwen3.8-27B-NVFP4"
MODEL_REVISION="7d6f8d4d72f56b92b3cdbf22f156b90e1bab0108"   # pinned for reproducibility
SERVED_NAME="qwen3.8-27b-nvfp4"

# Pinned backend image. NOT the image.lock default (0.25.0) — pinned to 0.27.1 to match the
# Inferact campaign, so a baseline difference cannot be an image difference. 0.27.1 is also the
# version that carries the qwen3_5 arch work (#50210) and the SM121 kernel-detection fix (#49904).
VLLM_IMAGE="vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"   # v0.27.1
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  # --- functional (serving features; CONFIRMED against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20}'   # model-recommended THINKING-mode sampling (generation_config.json + card)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()

# Thinking-OFF kwargs for the Gate-2 generative eval serve (AGENTS.md → thinking-OFF generative eval).
# Same base model as the Inferact campaign, where this value was validated end to end (Gate 1 PASS,
# gsm8k FULL think-off = 95.45 with non-empty content). PROBE anyway if smoke behaves oddly: a
# pre-closed '<think></think>' render makes some archs emit zero tokens (NemotronH, gsm8k 0.0).
AHL_THINK_OFF_KWARGS='{"enable_thinking": false}'

# NOTE for the tune loop (do NOT apply here — one change at a time, from the baseline):
#   - --tool-call-parser qwen3_xml is the alternative the community recipe for this model ships.
#     qwen3_coder passes our Gate-1 tool-call check on this base model, so the baseline keeps it
#     for comparability; qwen3_xml is a functional candidate to test, not a perf one.
#   - This repo ships model_mtp.safetensors, so --speculative-config '{"method":"mtp",...}' is
#     available. The Inferact campaign's answer was n=3 (+43.8% c16); re-verify rather than assume,
#     since the optimum is checkpoint-dependent.
