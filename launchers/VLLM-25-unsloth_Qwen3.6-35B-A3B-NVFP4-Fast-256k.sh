#!/usr/bin/bash
#
# PRODUCTION LAUNCHER — unsloth Qwen3.6-35B-A3B-NVFP4-Fast, 256K serving variant (20260712).
# Backed by the promoted VLLM-25-unsloth_Qwen3.6-35B-A3B-NVFP4-Fast_final.sh (campaign: dethroned
# the RedHatAI quant — chat c16 404.95 +12.7% / c1 76.98 +39.5% N=3, quality tied-or-better:
# mmlu 81.32, gsm8k(think-off) 96.0, mmlu_pro 68.57). ONE delta vs the _final: max-model-len
# 8192 -> 262144 (full native context; KV pool set by util 0.5, ~2.8x concurrency at full window).
# KNOWN ISSUE (upstream, all 0.25 thinking+MTP configs): response_format json_object output is
# intermittently corrupted; forced tool_choice works on 0.25 xgrammar. vLLM #48228/#46118/#34650,
# fix PR #44927 + RFC #48197 pending — retest on 0.26.

export VLLM_IMAGE="vllm/vllm-openai@sha256:fc56161ee42a011aeee78b65d0a81b6683c7d04402fd40503d14d4d6c98f07cb"  # v0.25.0
export MODEL="unsloth/Qwen3.6-35B-A3B-NVFP4-Fast"
export MODEL_REVISION="1c3f884bc99aac2524f6d49bcbac8c88401afd66"   # pinned for reproducibility

# Full native context for long-context serving (override at runtime for a smaller ceiling).
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"

NAME="${NAME:-vllm-qwen3.6-35b-a3b-nvfp4-fast}"
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
		--served-model-name qwen3.6-35b-a3b-nvfp4-fast \
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
