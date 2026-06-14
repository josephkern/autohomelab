#!/usr/bin/env bash
# TUNED VARIANT (kvfp8) on vLLM 0.23.0 — base: runbooks/RedHatAI/gemma-4-31B-it-NVFP4/baseline.sh
# Deltas vs base: + --kv-cache-dtype fp8_e4m3
# Hypothesis: Halves KV footprint -> ~2x KV capacity (baseline KV-starved at c16/c32) -> bigger batches -> higher c16/c32. The 8B campaign's win. Numeric-risky -> eval gsm8k+mmlu_pro if it wins.

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
  --kv-cache-dtype fp8_e4m3
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
