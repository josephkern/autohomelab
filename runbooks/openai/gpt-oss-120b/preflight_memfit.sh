#!/usr/bin/env bash
# PRE-FLIGHT variant of baseline.sh — copy of baseline + TWO deltas, to confirm gpt-oss-120b
# (MXFP4 MoE) actually serves on the GB10 sm_121 WITHOUT wedging the unified-memory box:
#   (1) --gpu-memory-utilization 0.85 -> 0.62
#   (2) + --enforce-eager
# WHY (root cause of the host hang/reboot, from the 06-21 17:56 serve log):
#   On the GB10 the GPU pool IS host RAM. At 0.85 util vLLM claims ~103 GiB of the 121.6 GiB
#   shared pool, leaving only ~48 GiB for the OS + the 60.77 GiB checkpoint read (vLLM logged
#   "Checkpoint size 60.77 GiB > 90% of available RAM 48.39 GiB"). It limps through the load,
#   then the post-load torch.compile + CUDA-graph capture (auto-bumped to size 1024) materializes
#   the over-commit -> MemAvailable->0 -> swap thrash -> kernel livelock -> whole box hangs (no
#   VRAM to isolate the OS) -> reboot. This is the CLAUDE.md hazard: "high util starves the OS and
#   destabilizes the box." (cf. Nemotron-120B survived 0.85 because it does NOT auto-bump cudagraph.)
#   - 0.62 util => 0.62*121.6 ~= 75 GiB GPU = 60.77 GB weights + ~14 GiB KV (ample at maxlen 8192),
#     leaving ~46 GiB headroom for the OS + loader (same weights-fit ratio Nemotron used).
#   - --enforce-eager skips the compile + cudagraph-capture phase entirely — that's the phase the
#     box wedges in. Once this serves clean, LIFT --enforce-eager to characterize the real config
#     (and consider capping the auto-1024 capture size before re-enabling cudagraphs).
# NOTE: the prior preflight's VLLM_MARLIN_USE_ATOMIC_ADD=1 was DROPPED — source (marlin_utils.py)
#   shows it's an experimental *performance* feature (atomic-add split-K reduce) that vLLM RECOMMENDS
#   enabling, NOT a race fix; it does nothing for this hang. The MARLIN backend is auto-selected and
#   keeps weights 4-bit (no upcast balloon) — confirmed in the serve log.
# If this serves + smokes green, fold util 0.62 into baseline.sh and tune cudagraphs from there.
# node_fp:   gb10-1988a9714b4e  |  gpu: NVIDIA GB10 x1 (unified memory)

MODEL="openai/gpt-oss-120b"
MODEL_REVISION="b5c939de8f754692c1647ca79fbf85e8c1e70f8a"   # pinned for reproducibility
SERVED_NAME="gpt-oss-120b"

# Pinned backend image (from backends/vllm/image.lock registry). Image version is a per-model
# tuning dimension — change it here for a tuned variant if a newer image helps.
VLLM_IMAGE="vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f"
VLLM_ENTRYPOINT_SERVE=true   # image ENTRYPOINT already runs `vllm serve`

VLLM_FLAGS=(
  # --- performance (tuned by the loop) ---
  --tensor-parallel-size 1
  --gpu-memory-utilization 0.62      # unified pool: 0.62*121.6 ~= 75 GiB = 60.77 GB weights + ~14 GiB KV;
                                     # leaves ~46 GiB for OS+loader. 0.85 starved the OS -> host wedge (see header).
  --enforce-eager                    # PREFLIGHT ONLY: skip torch.compile + cudagraph capture (the wedge phase).
                                     # LIFT this once the model serves stably to characterize the real config.
  --max-model-len 8192               # covers chat(512/256) + coder(4096/1024); native ctx is 131072 (yarn x32)
  # --- functional (serving features; CONFIRM against the model card; smoke.sh validates) ---
  # MXFP4 experts auto-detected (quant_method=mxfp4 -> gpt_oss_mxfp4); attn/router/embed/lm_head stay BF16.
  # gpt-oss uses native Harmony output parsing; vLLM auto-sets reasoning_parser=openai_gptoss (set explicit).
  --reasoning-parser openai_gptoss
  --enable-auto-tool-choice --tool-call-parser openai   # gpt-oss tool parser registered name is "openai"
)
# Optional env passed into the container, e.g. VLLM_ENV=( "VLLM_ATTENTION_BACKEND=TRITON_ATTN" )
VLLM_ENV=()
