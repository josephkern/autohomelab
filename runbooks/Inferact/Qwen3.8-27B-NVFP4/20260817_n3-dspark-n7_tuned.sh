#!/usr/bin/env bash
# TUNED VARIANT (n3-dspark-n7) — base: runbooks/Inferact/Qwen3.8-27B-NVFP4/20260816_mtp-n3_tuned.sh
# Deltas vs base: speculative-config mtp/n=3 -> dspark drafter RadixArk/Qwen3.8-27B-DSpark, n=7,
#   draft_sample_method "probabilistic".
# Hypothesis: DSpark is a DFlash block-diffusion drafter with a confidence head that picks the draft
#   length dynamically. The drafter card publishes a MEAN ACCEPTANCE LENGTH OF 3.39 (per-workload
#   2.71-4.57) at block size 7. Our MTP n=3 winner is emitting roughly 1.7 tokens per target pass
#   (c1 17.58 against a 10.34 no-spec baseline), so if anything close to 3.39 transfers this is
#   the largest single lever left in the campaign -- potentially ~2x on c1. Decode here is pinned
#   at the memory-bandwidth wall (~255 GB/s, 93% of the GB10's 273 GB/s peak, independently
#   reproduced by the FF711 llama.cpp campaign), and raising accepted-length is the ONLY way past a
#   bandwidth wall: it buys more emitted tokens per weight-read, rather than more reads.
# Provenance: this is the config from an X/twitter post (0xBakeer) claiming 75 tok/s, translated
#   from the drafter card's SGLang recipe (--speculative-dspark-block-size 7 -> n=7). The 75 tok/s
#   headline does NOT survive arithmetic on this box: 10.34 target passes/s x 3.39 accepted = ~35
#   tok/s, and their FP8 target is HEAVIER than our NVFP4 so it would be slower still. We are
#   testing the mechanism because the published acceptance is good, NOT because we expect 75.
# MISMATCH TO WATCH: the drafter was trained against the FP8 target (Qwen/Qwen3.8-27B-FP8) with an
#   unquantized BF16 draft; our target is the NVFP4 build. Same base model and hidden geometry, but
#   a drafter keys off target hidden states, so NVFP4's different numerics may cost acceptance.
#   That is precisely the empirical question -- if acceptance collapses, this is the answer.
# Risk: HIGH, and NUMERIC-RISKY. draft_sample_method "probabilistic" is NOT greedy: it loosens the
#   acceptance rule from exact-match rejection sampling, which is how acceptance length gets
#   inflated -- at the cost of no longer provably preserving the target's output distribution.
#   Our charter already records that ds4's DSpark is documented as divergent under greedy decode
#   (a DIFFERENT engine, but the same family of technique). So unlike MTP, a KEEP here does NOT
#   inherit the baseline's Gate 2: this config needs its OWN accuracy run, in the SAME session as
#   a reference re-measure, before it could ever be promoted.
# Requires: drafter download ~2.7 GB (1.36B params BF16), pre-fetched into the HF cache.
# TUNED VARIANT (mtp-n3) — base: runbooks/Inferact/Qwen3.8-27B-NVFP4/baseline.sh
# Deltas vs base: ADD --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
# Hypothesis: the value the Spark Arena GB10 recipe ships for this exact model
#   (spark-arena.com recipe 18733214, unsloth NVFP4 build, nvcr vllm 26.07). Deepest drafting wins
#   if acceptance holds up — but this arch has a SINGLE MTP layer re-run 3x, so acceptance should
#   decay fastest here. Testing it because the recipe is real GB10 evidence, NOT because we expect
#   it to win: Spark Arena is a PERF-ONLY leaderboard tuned for headline single-stream numbers,
#   with no quality gate and no c16 objective. Bracket member: n=1 vs n=2 vs n=3.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against Inferact_Qwen3.8-27B-NVFP4_Model_Card.md; scripts/smoke.sh validates.

MODEL="Inferact/Qwen3.8-27B-NVFP4"
MODEL_REVISION="6128240ebaf4eaa7bad2b3d1c72c37d677c5f462"   # pinned for reproducibility
SERVED_NAME="qwen3.8-27b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"   # v0.27.1
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.5
  --max-model-len 8192
  --speculative-config '{"method":"dspark","model":"RadixArk/Qwen3.8-27B-DSpark","num_speculative_tokens":7,"draft_sample_method":"probabilistic"}'
  # --- functional (serving features; CONFIRMED against the model card; smoke.sh validates) ---
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20}'   # model-recommended THINKING-mode sampling (generation_config.json + card)
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()

# Thinking-OFF kwargs for the Gate-2 generative eval serve (AGENTS.md → thinking-OFF generative eval).
# This model's chat template renders a PRE-CLOSED '<think>\n\n</think>\n\n' for enable_thinking=false —
# the same shape that made NemotronH emit zero tokens (gsm8k 0.0). PROBE the think-off serve before
# trusting generative scores; if `content` comes back empty, fall back to the model's own reduced-
# reasoning knob: AHL_THINK_OFF_KWARGS='{"reasoning_effort":"low"}'.
AHL_THINK_OFF_KWARGS='{"enable_thinking": false}'
