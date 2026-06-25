#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/unsloth/Qwen3.6-27B-NVFP4/20260624_mtp-n1_tuned.sh on 2026-06-25.
# Result: mtp-n1 (qwen3_5_mtp num_spec=1): chat c16 122.6->161.5 (+31.7%), c1 12.1->16.8 (+39.2%) — project's biggest MTP lift; gsm8k 98=98 lossless; smoke 4/4. STOCK 0.23.0 image (no patches). quality gsm8k98/mmlu84.3/mmlu_pro71.6.
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# TUNED VARIANT (mtp-n1) — base: runbooks/unsloth/Qwen3.6-27B-NVFP4/baseline.sh
# Deltas vs base: + `--speculative-config '{"method":"qwen3_5_mtp","num_speculative_tokens":1}'`.
# Hypothesis: native single-token MTP draft. This model has ONE MTP layer (mtp_num_hidden_layers=1),
#   so num_spec=1 fits it (n>1 reuses the single layer → lower acceptance). DGX-Spark forum reports
#   85-94% acceptance single-node on this exact model. Greedy-lossless. THE primary lever (dense, no MoE).
# Quality gate: spec-decode ⊥ loglikelihood (NaN prompt_logprobs); use generative gsm8k/mmlu_pro.
# If it won't LOAD (NVFP4+MTP less proven than FP8): see qwen3_next playbook (mtp.fc quant-ignore / gate_up_proj).
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against unsloth_Qwen3.6-27B-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="unsloth/Qwen3.6-27B-NVFP4"
MODEL_REVISION="890bdef7a42feba6d83b6e17a03315c694112f2a"   # pinned for reproducibility
SERVED_NAME="qwen3.6-27b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192              # native ctx 262144; benchmark shape covers chat(512/256)+coder(4096/1024)
  # NVFP4 (compressed-tensors W4A4) auto-detected — no explicit --quantization. ~26.4 GB weights → 0.5 util ample.
  --speculative-config '{"method":"qwen3_5_mtp","num_speculative_tokens":1}'   # DELTA: native MTP, single draft token
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder   # qwen3_coder XML <function=...> format (chat_template L53; hermes FAILED smoke)
  --reasoning-parser qwen3   # HYBRID reasoning: <think> CoT + enable_thinking TOGGLE → standard suite think-off path works
  --limit-mm-per-prompt '{"image":0}'   # MULTIMODAL (Qwen3_5ForConditionalGeneration) served TEXT-ONLY (matches our text suite; cf. gemma-4-31B)
  # MTP PRESENT (mtp_num_hidden_layers=1, preserved in this NVFP4 build) → tuned variant adds
  # --speculative-config '{"method":"qwen3_5_mtp","num_speculative_tokens":1}'. vLLM 0.23.0 has qwen3_5_mtp.py.
  # Forum (DGX Spark): MTP 85-94% accept single-node; dual-node allgather overhead caveat is N/A for our TP1.
  # NVFP4+MTP loading is LESS proven than FP8+MTP — if mtp.fc-quant/shape issues surface, see the qwen3_next playbook.
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
