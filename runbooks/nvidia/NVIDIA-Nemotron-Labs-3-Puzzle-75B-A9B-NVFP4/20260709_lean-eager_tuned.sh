#!/usr/bin/env bash
# TUNED VARIANT (lean-eager) — base: baseline.sh
# Deltas vs base: + `--enforce-eager` (skip torch.compile/CUDA-graph capture — the dominant startup
#   memory spike); gpu-memory-utilization 0.85 -> 0.72; max-model-len 131072 -> 16384; + `--max-num-
#   batched-tokens 8192` + `--max-num-seqs 8`; + VLLM_ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True.
# Hypothesis: HF discussion #1 (same GB10/DGX-Spark, vLLM 0.24.0) reports a ~160 GB startup RAM spike
#   (settles ~100 GB) that OOMs an unprovisioned box — the gpt-oss-120b failure mode. This lean config
#   holds the peak under our 121 GiB physical RAM: enforce-eager removes the compile/graph workspace,
#   expandable_segments cuts fragmentation, tight len/seqs shrink KV+activation reservations, and 0.72
#   util leaves ~34 GB physical headroom for the load transient. FEASIBILITY PROBE: get a green serve +
#   smoke first; MTP/async-sched/full-context are later levers. Served under a memory watchdog.
# node_fp:   gb10-1988a9714b4e
# gpu:       NVIDIA GB10 x1 (unified memory)

MODEL="nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4"
MODEL_REVISION="1d370e47fbc56d1019a471c2339663cdbbb5236f"   # pinned for reproducibility
SERVED_NAME="nvidia-nemotron-labs-3-puzzle-75b-a9b-nvfp4"

VLLM_IMAGE="vllm/vllm-openai@sha256:251eba5cc7c12fed0b75da22a9240e582b1c9e39f6fbc064f86781b963bd814f"  # v0.24.0
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.72   # DELTA: leave ~34GB physical headroom for the startup transient
  --max-model-len 16384           # DELTA: tight (benchmark shapes need <=5120); shrinks KV reservation
  --enforce-eager                 # DELTA: skip torch.compile/CUDA-graph capture (the big startup spike)
  --max-num-batched-tokens 8192   # DELTA: cap prefill activation working set
  --max-num-seqs 8                # DELTA: cap concurrent seqs (mamba state is per-seq)
  # --- functional / arch-correctness ---
  --trust-remote-code
  --mamba-backend flashinfer
  --mamba-ssm-cache-dtype float16
  --enable-mamba-cache-stochastic-rounding
  --mamba-cache-philox-rounds 5
  --override-generation-config '{"temperature":1.0,"top_p":0.95}'
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
  --reasoning-parser nemotron_v3
)
VLLM_ENV=( "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True" )   # DELTA: reduce allocator fragmentation

AHL_THINK_OFF_KWARGS='{"enable_thinking": false}'
