#!/usr/bin/bash
#
# Serve qwen3.6-35b-a3b-nvfp4 with vLLM on NVIDIA GB10 (Grace-Blackwell, sm_121).
# LONG-CONTEXT SERVING variant — adapted by hand from the auto-generated benchmark launcher
# (VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4.sh). Same validated 0.24.0 image + MTP n=2 + fp8 KV +
# flashinfer_cutlass MoE + functional flags; only ONE serving knob differs from the _final config:
#
#   MAX_MODEL_LEN  8192 -> 262144   (full native 256K context)
#   --gpu-memory-utilization         UNCHANGED at 0.5   (memory budget held fixed by request)
#
# CONCURRENCY at 256K with util fixed at 0.5: the KV pool is set by util, NOT by max-model-len, so
# it stays ~729,088 tokens (measured on this exact config at util 0.5). max-model-len only sets how
# much of that pool ONE request may claim:
#   full-256K concurrency = 729,088 / 262,144 ~= 2.8x   (i.e. ~2-3 simultaneous requests AT the full
#                                                         256K window; one 256K request fits easily)
# KV is allocated per-TOKEN, not per-slot, so short/normal requests don't pay for the big window —
# only requests that actually grow toward 256K compete for the pool. For everyday chat lengths the
# effective concurrency stays in the hundreds (same 729k-token pool as the 8K config).
# VERIFY on startup: the vLLM log prints "Maximum concurrency for 262144 tokens per request: N.NNx" —
# expect ~2.8x. Want a higher floor at 256K? That requires raising util (out of scope here) — see the
# Qwen3-Next -256k-c4 launcher for the util-raised pattern.
#
# 262144 is the model's TRAINED context (max_position_embeddings) — no RoPE/YaRN extrapolation.
# Serves the OpenAI-compatible API on http://0.0.0.0:${PORT:-8000}/v1. Weights load from the host
# HF cache ($HF_HOME or ~/.cache/huggingface); set HF_TOKEN to pull on first run. Runs DETACHED:
#   docker logs -f <NAME>   # follow startup/serving logs    (NAME defaults below)
#   docker rm -f  <NAME>    # stop + remove the container
#   PORT=8001 NAME=foo ./VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4-256k.sh   # override port / name
#   MAX_MODEL_LEN=131072 ./VLLM-24-…-256k.sh                              # smaller ceiling (higher conc)
#

# Upstream vLLM v0.24.0 pinned by digest for reproducibility — the release tag is already immutable;
# the digest makes it byte-exact. Blackwell kernels are built sm_120 (forward-compatible to the
# GB10's sm_121); FlashInfer JITs the FP4/MoE paths for the device at runtime.
export VLLM_IMAGE="vllm/vllm-openai@sha256:251eba5cc7c12fed0b75da22a9240e582b1c9e39f6fbc064f86781b963bd814f"  # v0.24.0
export MODEL="RedHatAI/Qwen3.6-35B-A3B-NVFP4"
export MODEL_REVISION="e850c696e6d75f965367e816c16bc7dacd955ffa"   # pinned for reproducibility

# Full native context for long-context serving (override at runtime for a smaller ceiling).
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"

NAME="${NAME:-vllm-qwen3.6-35b-a3b-nvfp4}"
PORT="${PORT:-8000}"
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}"

# Replace any prior container of this name.
docker rm -f "${NAME}" 2>/dev/null || true

docker run -d --name "${NAME}" \
	--gpus all \
	--ipc=host \
	-p "${PORT}:8000" \
	-v "${HF_CACHE}:/root/.cache/huggingface" \
	-e TOKENIZERS_PARALLELISM=false \
	-e "HF_TOKEN=${HF_TOKEN:-}" \
	"${VLLM_IMAGE}" \
		"${MODEL}" \
		--served-model-name qwen3.6-35b-a3b-nvfp4 \
		--revision "${MODEL_REVISION}" \
		--max-model-len "${MAX_MODEL_LEN}" \
		--tensor-parallel-size 1 \
		--gpu-memory-utilization 0.5 \
		--max-num-batched-tokens 16384 \
		--enable-chunked-prefill \
		--quantization compressed-tensors \
		--kv-cache-dtype fp8_e4m3 \
		--moe-backend flashinfer_cutlass \
		--speculative-config '{"method":"mtp","num_speculative_tokens":2}' \
		--enable-prefix-caching \
		--enable-auto-tool-choice \
		--tool-call-parser qwen3_coder \
		--reasoning-parser qwen3 \
		--override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"presence_penalty":1.5}'
