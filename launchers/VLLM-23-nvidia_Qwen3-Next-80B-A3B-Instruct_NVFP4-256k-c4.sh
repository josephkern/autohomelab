#!/usr/bin/bash
#
# Serve qwen3-next-80b-a3b-instruct-nvfp4 with vLLM on NVIDIA GB10 (Grace-Blackwell, sm_121).
# LONG-CONTEXT SERVING variant — adapted by hand from the auto-generated benchmark launcher
# (VLLM-23-nvidia_Qwen3-Next-80B-A3B-Instruct_NVFP4.sh). Same validated image + MTP + functional
# flags; only the two SERVING knobs differ from the _final/benchmark config:
#
#   MAX_MODEL_LEN  8192  -> 262144   (full native 256K context)
#   --gpu-memory-utilization  0.5 -> 0.72   (KV pool sized to hold concurrency >=4 at 256K)
#
# WHY 0.72 fits conc>=4 at 256K on a 121.6 GB unified pool (despite scripts/kv_calc.py saying "OVER"):
# Qwen3-Next is a HYBRID — full_attention_interval=4, so only 12 of 48 layers carry a context-scaled
# KV cache (the other 36 are linear/Gated-DeltaNet with fixed-size recurrent state). Real KV is 1/4 of
# kv_calc's all-attention estimate:
#   per-token KV = 12 layers x 2 kv-heads x 256 head_dim x 2 (K+V) x 2 B (fp16) = 24 KiB/token
#   256K seq     = 262144 x 24 KiB  ~= 6.3 GB / sequence
#   weights 47.3 GB + conc4 KV ~25.2 GB + ~5 GB runtime/MTP/cudagraph ~= ~78 GB  (util ~0.64)
#   util 0.72 -> ~87.6 GB to vLLM -> ~35 GB KV pool -> ~5.5x concurrency at full 256K (>=4 with margin),
#   leaving ~34 GB (28%) of the shared pool for the OS (well under the 0.85 unified-mem risk line).
# VERIFY on startup: the vLLM log prints "Maximum concurrency for 262144 tokens per request: N.NNx" —
# confirm N >= 4. Nudge util up toward 0.80 if you want a higher floor; down if the box gets starved.
#
# Serves the OpenAI-compatible API on http://0.0.0.0:${PORT:-8000}/v1. Weights load from the host
# HF cache ($HF_HOME or ~/.cache/huggingface); set HF_TOKEN to pull on first run. Runs DETACHED:
#   docker logs -f <NAME>   # follow startup/serving logs    (NAME defaults below)
#   docker rm -f  <NAME>    # stop + remove the container
#   PORT=8001 NAME=foo ./VLLM-23-nvidia_Qwen3-Next-80B-A3B-Instruct_NVFP4-256k-c4.sh   # override port / name
#

# NOTE: this config uses a LOCALLY-BUILT vLLM 0.23.0 image (`vllm-openai:0.23.0-qwen3nextmtp-fix`), not a portable
# upstream digest — it must be built on the host before this launcher will run. See its
# Dockerfile under backends/vllm/images/ and the matching entry in backends/vllm/image.lock.
# Blackwell kernels are sm_120 (forward-compatible to the GB10's sm_121); FlashInfer JITs FP4/MoE.
export VLLM_IMAGE="vllm-openai:0.23.0-qwen3nextmtp-fix"  # 0.23.0
export MODEL="nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4"
export MODEL_REVISION="8fb2682f136cf94d932a498f18cb1e428832a912"   # pinned for reproducibility

# Full native context for long-context serving (override at runtime if you want a smaller ceiling).
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
# KV-pool share of the unified pool. 0.72 holds conc>=4 at 256K (see header math).
export GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.72}"

NAME="${NAME:-vllm-qwen3-next-80b-a3b-instruct-nvfp4}"
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
		--served-model-name qwen3-next-80b-a3b-instruct-nvfp4 \
		--revision "${MODEL_REVISION}" \
		--max-model-len "${MAX_MODEL_LEN}" \
		--tensor-parallel-size 1 \
		--gpu-memory-utilization "${GPU_MEM_UTIL}" \
		--speculative-config '{"method":"qwen3_next_mtp","num_speculative_tokens":1}' \
		--override-generation-config '{"temperature":0.7,"top_p":0.8,"top_k":20}' \
		--enable-auto-tool-choice \
		--tool-call-parser hermes
