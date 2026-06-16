#!/usr/bin/env bash
# TUNED VARIANT (trust-remote-code) — base: runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/baseline.sh
# Deltas vs base: + `--trust-remote-code`, with MODEL_REVISION -> df929bc (the revision that ships
#   modeling_nemotron_h.py + super_v3_reasoning_parser.py; **identical weights** to baseline's b2b9a615,
#   verified by shard sha — so this is a clean A/B of the model's-own-code path vs vLLM's built-in).
# Hypothesis: NOT expected to raise c16 — vLLM uses its BUILT-IN NemotronHForCausalLM for this registered
#   arch regardless of trust_remote_code (the flag gates custom config/tokenizer loading, not the compute
#   kernels). Run to CONFIRM it's throughput-inert (≈baseline within noise) and doesn't break correctness.
#   (User-requested 7th candidate, run after the main 6-queue.)
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4_Model_Card.md; scripts/smoke.sh validates.
#
# Model: NemotronHForCausalLM — hybrid Mamba-Transformer ("Nemotron-H"), latent-MoE, 22 experts/tok,
#   native 256K context. ModelOpt-quantized (quant_algo=MIXED_PRECISION: NVFP4 weights + some FP8
#   layers; KV scheme baked in as FP8). Reasoning + tool-calling. vLLM 0.23.0 registers the arch +
#   the nemotron_v3 reasoning parser natively (verified) — no trust_remote_code needed.
# Config derived from the vLLM DGX-Spark blog (2026-06-01) functional flags, RESET for SOLO THROUGHPUT:
#   - gpu-memory-utilization 0.85 (NOT the unified 0.50 default): weights alone are ~75 GB = 0.62 of
#     the 121.6 GiB pool, so 0.50 can't load. 0.85 (~103 GB) fits weights + ~20 GB KV + headroom (blog Fig-2).
#   - --max-num-seqs 4 from the blog OMITTED: it's a single-user latency cap that throttles c16/c32
#     (cf. the 35B baseline dropping its --max-num-seqs 2). Keep as a tune candidate, not the baseline.
#   - NO --quantization (modelopt auto-detected), NO --moe-backend/--kv-cache-dtype/--speculative-config
#     (mtp): all left to vLLM defaults for the first green serve — they are TUNE-LOOP candidates (Fig-4
#     slider: FP4 backend, validated KV, async scheduling, MTP spec-decode).

MODEL="RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"
MODEL_REVISION="df929bc77dece5f0483ce3fcf3f3f716a81e3ca9"   # DELTA: df929bc has the custom modeling code (identical weights to b2b9a615)
SERVED_NAME="nvidia-nemotron-3-super-120b-a12b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --trust-remote-code             # DELTA: load the model's own configuration_/modeling_nemotron_h.py
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.85   # 75 GB weights need this on the 121.6 GiB unified pool (see header)
  --max-model-len 8192            # benchmark shapes; native is 256K — raise for long-context runs
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95}'   # model-recommended sampling (generation_config.json)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser nemotron_v3
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()

# Eval overlay — thinking-OFF generative eval (suite.sh / AHL_THINK_OFF=1). NemotronH emits ZERO
# tokens from the pre-closed `<think></think>` that enable_thinking=false produces (gsm8k think-off
# = 0.0); its reduced-reasoning knob is `low_effort`, which keeps the working `<think>\n` format and
# puts the answer in `content` (verified: "17x4" -> content "68"). Consumed by adapter.sh ONLY on the
# AHL_THINK_OFF eval serve — inert for the deployed/throughput serve and think-on loglikelihood mmlu.
AHL_THINK_OFF_KWARGS='{"low_effort": true}'
