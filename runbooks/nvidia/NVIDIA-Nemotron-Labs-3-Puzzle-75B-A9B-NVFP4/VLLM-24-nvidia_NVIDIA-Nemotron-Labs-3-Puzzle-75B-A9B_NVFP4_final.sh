#!/usr/bin/env bash
# FINAL (campaign-selected) — promoted from runbooks/nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4/20260709_mtp-n1_tuned.sh on 2026-07-09.
# Result: MTP n=1 winner: chat c16 154.3->173.1 (+12%), c1 20.4->29.5 (+45%), coder c32 70.7->114.1 (+61%); 90-93%/77% accept c1/c16; quality lossless (mmlu 83.67); smoke 4/4. enforce-eager MEMORY-MANDATORY on GB10 (else ~160GB compile spike OOMs; user declined swap).
# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.
# TUNED VARIANT (mtp-n1) — base: runbooks/nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4/baseline.sh
# Deltas vs base: + `--speculative-config '{"method":"mtp","num_speculative_tokens":1}'` (native MTP, n=1).
# Hypothesis: model ships 1 native MTP layer (num_nextn_predict_layers=1); verified-lossless spec decode
#   raises decode tok/s on this bandwidth-bound MoE. MTP was the DOMINANT lever on the Nemotron-3-Super
#   sibling (+22.8% c16) and the Qwen MoEs. RISK: discussion #1 saw POOR acceptance at num_spec=4
#   (10-20 t/s) — n=1 is the accept-friendly setting (1 MTP layer natural fit); may still underperform
#   the sibling if the NAS-Puzzle compression hurt draft alignment. Quality is greedy-lossless (spec
#   decode) but loglikelihood mmlu returns NaN under spec-decode -> quality gate via generative gsm8k.
# BASELINE — first green serve for the standard suite. Derived from the node profile +
# the model card's recommended (non-MTP) vLLM serve recipe, adapted to single-GPU (TP=1).
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)
# Complete reproducible unit: pinned image + model + serving flags (performance + functional).
# Tune by COPYING to <YYYYMMDD>_<change>_tuned.sh (one perf change); keep this baseline unchanged.
# Confirm the FUNCTIONAL flags below against nvidia_NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4_Model_Card.md; scripts/smoke.sh validates.
#
# Model: NemotronHPuzzleForCausalLM (model_type nemotron_h_puzzle) — NAS-"Puzzle"-compressed
#   hybrid: interleaved Mamba2 + latent-MoE (512 routed + 1 shared expert) + Attention, 88 layers,
#   9B active / 75B total, native 262K context. ModelOpt MIXED_PRECISION quant: routed experts NVFP4
#   (W4, group_size 16), Mamba/shared-expert projections FP8. Reasoning + tool-calling; native MTP
#   (num_nextn_predict_layers=1). vLLM 0.24.0 registers the arch (-> nemotron_h module) + nemotron_v3
#   reasoning parser + nemotron_h_mtp spec method natively (verified in-image). 53.5 GB download.
#
# MEMORY-MANDATORY on this box (validated 2026-07-09, feasibility probe 20260709_lean-eager):
#   HF discussion #1 (identical GB10/DGX-Spark, vLLM 0.24.0) reports a ~160 GB startup RAM spike that
#   OOMs an unprovisioned box (settles ~100 GB) — the gpt-oss-120b failure mode. ROOT CAUSE = the
#   torch.compile / CUDA-graph-capture workspace. FIX: --enforce-eager removes it entirely → measured
#   peak 99.5 GB (== steady state), ZERO swap, ~25 GB headroom on our 121.6 GiB pool. The user declined
#   adding swap, so --enforce-eager + expandable_segments are REQUIRED here (not optional perf knobs).
#   Cost: no CUDA graphs (some decode throughput left on the table) — the price of fitting without swap.
#
# Baseline design (vendor non-MTP recipe + memory-mandatory flags, minus project tune-levers):
#   - gpu-memory-utilization 0.72: 53.5 GB weights + KV/mamba fit with headroom; KV profiled to 4.8M
#     tokens = 293x concurrency at 16K, so plenty. (0.85 would work post-enforce-eager but 0.72 keeps
#     a comfortable safety margin on the shared unified pool.)
#   - max-model-len 16384: covers both benchmark shapes (coder 5120) with 293x concurrency headroom;
#     native context is 262K (a long-context launcher is a separate artifact).
#   - max-num-seqs 64: covers the c32 benchmark level (probe used 8). Total memory is fixed by gpu-mem,
#     so this trades KV-token headroom for seq slots — peak stays ~99.5 GB.
#   - Mamba correctness set (vendor-recommended for this fp16-mamba-cache NVFP4 hybrid; NOT perf):
#     --mamba-backend flashinfer, --mamba-ssm-cache-dtype float16 + stochastic rounding (philox 5).
#     --trust-remote-code for the Puzzle heterogeneous per-layer config.
#   - DEFERRED to the tune loop (card includes them; project treats as levers): --speculative-config
#     (MTP — but discussion #1 saw POOR acceptance at n=4/10-20 t/s; test n=1 and MTP-off), --async-
#     scheduling, --enable-expert-parallel (multi-GPU; inert on TP=1), --moe-backend, --kv-cache-dtype.

MODEL="nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4"
MODEL_REVISION="1d370e47fbc56d1019a471c2339663cdbbb5236f"   # pinned for reproducibility
SERVED_NAME="nvidia-nemotron-labs-3-puzzle-75b-a9b-nvfp4"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:251eba5cc7c12fed0b75da22a9240e582b1c9e39f6fbc064f86781b963bd814f"  # v0.24.0
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.72   # safe on the 121.6 GiB unified pool post-enforce-eager (see header)
  --max-model-len 16384           # covers both benchmark shapes; native 262K (see header)
  --max-num-seqs 64               # covers the c32 benchmark level
  --enforce-eager                 # MEMORY-MANDATORY: removes the ~160GB compile spike -> peak 99.5GB
  --speculative-config '{"method":"mtp","num_speculative_tokens":1}'   # DELTA: native MTP spec decode (n=1)
  # --- functional / arch-correctness (vendor-recommended for this hybrid NVFP4 model; smoke.sh validates) ---
  --trust-remote-code                          # Puzzle NAS heterogeneous per-layer config
  --mamba-backend flashinfer                   # hybrid-Mamba2 backend (card-recommended)
  --mamba-ssm-cache-dtype float16              # card-recommended mamba SSM cache dtype ...
  --enable-mamba-cache-stochastic-rounding     # ... with stochastic rounding to hold accuracy at fp16
  --mamba-cache-philox-rounds 5
  --override-generation-config '{"temperature":1.0,"top_p":0.95}'   # model-recommended sampling
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser nemotron_v3
)
# expandable_segments MEMORY-MANDATORY (reduces allocator fragmentation during the load transient).
VLLM_ENV=( "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True" )

# Eval overlay — thinking-OFF generative eval (suite.sh / AHL_THINK_OFF=1). This model has a real
# enable_thinking switch (default {"enable_thinking": false}), unlike Nemotron-3-Super which needed
# {"low_effort": true} to avoid zero-token output from a pre-closed <think></think>. PROBE think-off
# content non-empty at baseline before trusting generative scores; switch to low_effort if empty.
AHL_THINK_OFF_KWARGS='{"enable_thinking": false}'
