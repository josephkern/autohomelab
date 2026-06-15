#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/RedHatAI/gemma-4-31B-it-NVFP4/baseline.sh on 2026-06-15.
# Result: Campaign winner by default: 5-candidate tune queue. Only kvfp8 moved c16 (+23.8%) but FAILED quality (mmlu_pro -4.3%, gsm8k ~-4-5%) -> baseline is the only config passing all 3 gates. kvfp8_tuned kept as optional speed-mode. c16=109; gsm8k=73.0/mmlu_pro=48.36; native cutlass FP4.
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# AUTO-GENERATED baseline by scripts/gen_baseline.py — derived from the node profile, then the
# functional flags were CONFIRMED against the RedHatAI HF model card. node_fp: gb10-1988a9714b4e.
# gpu: NVIDIA GB10 x1 (unified memory).
# Model: gemma-4-31B-it, NVFP4 (nvfp4-pack-quantized / compressed-tensors, auto-detected — no
#   --quantization needed). DENSE (not MoE → no --moe-backend). Multimodal arch
#   (Gemma4ForConditionalGeneration) served TEXT-ONLY here. Hybrid attention (sliding-window 1024 +
#   full every 6th layer, 60 layers) handled by vLLM automatically. Native context 256K; baseline
#   capped at 8192 for the benchmark shape (raise for long-context serving).
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.

MODEL="RedHatAI/gemma-4-31B-it-NVFP4"
MODEL_REVISION="c4905986988f1406d7d7d80200d81099977a9123"   # pinned for reproducibility
SERVED_NAME="gemma-4-31b-it-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  # --- functional (serving features; CONFIRMED against the HF model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":64}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice
  --tool-call-parser gemma4        # HF card: function calling via the gemma4 parser
  --reasoning-parser gemma4        # HF card: thinking/reasoning mode via the gemma4 parser
  --limit-mm-per-prompt '{"image":0}'   # TEXT-ONLY benchmark: Gemma4ForConditionalGeneration is
                                   # multimodal; card's tip (JSON form on 0.23.0) — skip vision encoder mem
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
