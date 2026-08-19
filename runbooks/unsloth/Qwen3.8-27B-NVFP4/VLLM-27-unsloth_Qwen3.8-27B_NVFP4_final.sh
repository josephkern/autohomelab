#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/unsloth/Qwen3.8-27B-NVFP4/20260818_mtp-n3_tuned.sh on 2026-08-19.
# Result: MTP n=3 on the unsloth NVFP4 build: chat c16 136.36->206.50 (+51.4% over baseline, +20.7% over the Inferact final); coder c32 +91.0%; quality EQUAL on gsm8k FULL (95.98) and BETTER on mmlu_pro FULL (70.38 vs 66.81)
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# TUNED VARIANT (mtp-n3) — base: runbooks/unsloth/Qwen3.8-27B-NVFP4/baseline.sh
# Deltas vs base: ADD --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
# Hypothesis: MTP was the entire Inferact campaign (+43.8% c16, +70% c1) and this repo ships
#   model_mtp.safetensors, so the drafter is available here too. Depth is bracketed rather than
#   inherited: Inferact peaked at n=3 and the curve was NON-MONOTONE (n=1/n=2 ~151, n=3 168,
#   n=4 158, n=5 151), and this checkpoint runs a DIFFERENT FP4 GEMM path
#   (FlashInferCutlassNvFp4 + CutlassFP8, vs Marlin on the earlier NVFP4 work), so both the
#   per-draft cost and the acceptance rate can differ. Re-derive, do not assume.
# Expected interaction: MTP is a BANDWIDTH-bound win that decays as the batch fills, while this
#   checkpoint's advantage is COMPUTE-bound and grows with batch. If they stack, chat c16 should
#   clear the promoted Inferact final (171.12) from the 136.36 baseline.
# Risk: LOW. vLLM MTP is greedy-lossless, so Gate 2 carries over; failure mode is serve_fail.
# EDITED 20260818 per program.md §0.4 (confirm functional flags; pin the campaign image).
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
#
# WHY THIS CAMPAIGN EXISTS: this is the SAME BASE MODEL as the Inferact/Qwen3.8-27B-NVFP4
# campaign — Qwen/Qwen3.8-27B's config matches both checkpoints on every field (hidden 5120,
# 64 layers, vocab 248320, heads 24/4, head_dim 256, intermediate 17408, linear 16/48,
# full_attention_interval 4, mtp 1) — but a DIFFERENT NVFP4 quantization.
#
# MEASURED on-disk weights (20260818, after download — NOT the HF API's parameter-byte estimate,
# which reported ~19.9 GB and understated it):
#     Inferact  25.53 GB  (6 shards, MTP head included)
#     unsloth   23.42 GB  (model.safetensors 22.57 + model_mtp.safetensors 0.85)
# => unsloth is 8.3% lighter, so the naive bandwidth-bound prediction is c1 x1.09.
#
# Decode on this box is pinned at the memory-bandwidth wall (~255 GB/s of the GB10's 273 GB/s peak,
# reproduced independently by the FF711 llama.cpp campaign), so bytes-per-token maps almost directly
# to c1 tok/s. FALSIFIABLE PREDICTION for the baseline: Inferact's no-spec c1 was 10.34, so if the
# two checkpoints differ ONLY in bytes, unsloth baseline c1 should land near 11.2. A materially
# different number means the quantization differs in more than size (which layers were kept at
# higher precision, and therefore which kernels run) — and that is worth knowing either way.
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
  --gpu-memory-utilization 0.6
  --max-model-len 262144
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
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

# ── SERVING PROFILE CHANGE 20260819 (post-promotion, user directive) ──────────────────────────
# --gpu-memory-utilization 0.5 -> 0.6 and --max-model-len 8192 -> 262144 (model native).
#
# WHY: the deployment is one long-context orchestrator (>66k) fanning out to short-context
# subagents. --max-model-len is a CEILING, not a reservation — vLLM allocates KV per token as
# sequences grow — so raising it costs nothing for short sequences and simply permits the
# orchestrator to grow. util 0.6 buys pool headroom for the fan-out.
#
# CAPACITY (from the engine-reported 283,989 tokens at util 0.5, measured 20260819):
#   util 0.5 -> ~283,900 live tokens      util 0.6 -> ~377,300 live tokens
#   a 128k orchestrator at util 0.6 leaves room for ~30 concurrent 8k subagents
#   at 256k context: 1 session at util 0.5, still only 1 at util 0.6 (2 needs util ~0.76)
#
# ⚠ NOT RE-VALIDATED AT THESE SETTINGS. All three gates were passed at util 0.5 / ctx 8192
# (SUITE-de23b412.md). This file therefore no longer matches the configuration that was gated.
# Known risks: (1) our single util 0.6 datapoint (Inferact, 20260816) cost 12.2 GB of shared pool
# for -0.6% c16 — on unified memory that pressure lands on the OS, not just the GPU; (2) no smoke,
# eval or bench has been run at ctx 262144. Re-run `scripts/suite.sh` on this file before treating
# it as gate-validated again.
