# openai/gpt-oss-120b — logbook (GB10 node #1)

**STATUS: ABANDONED (2026-06-22).** Never reached a green serve on GB10 sm_121. Repeatedly wedged the
unified-memory host (livelock → reboot) during the post-weight-load phase. Parked, not promoted.
Runbooks + model card kept as the project record. Revisit only on a vLLM image / GB10-memory-mgmt
change (see "If revisited" below).

## Environment
- node_fp: `gb10-1988a9714b4e` — NVIDIA GB10 x1, sm_121, aarch64, ~121.6 GiB **unified** LPDDR5X
- driver 580.159.03, CUDA 13.0
- backend: vLLM **0.23.0** (image `vllm/vllm-openai@sha256:6d8429e3…`)
- model: `openai/gpt-oss-120b` rev `b5c939de8f754692c1647ca79fbf85e8c1e70f8a`, **MXFP4** MoE
  (117B total / 5.1B active, 128 experts/4-per-tok), ~61 GiB on disk

## What we tried
1. **baseline.sh** — `--gpu-memory-utilization 0.85`, cudagraphs on. At 0.85 vLLM claims ~103 GiB of
   the 121.6 GiB shared pool, leaving ~48 GiB for OS + the 60.77 GiB checkpoint read. It limps
   through the load, then post-load compile + CUDA-graph capture (gpt-oss auto-bumps capture size to
   1024) materializes the over-commit → MemAvailable→0 → swap thrash → kernel livelock → **whole box
   hangs → reboot**. (No VRAM to isolate the OS on a unified node — the CLAUDE.md "high util starves
   the OS" hazard, in its worst form.)
2. **preflight_memfit.sh** — two deltas to make it fit: `--gpu-memory-utilization 0.62` (→ ~75 GiB
   GPU = 60.77 GiB weights + ~14 GiB KV, ~46 GiB OS headroom) **and** `--enforce-eager` (skip the
   torch.compile + cudagraph-capture phase that the box wedges in). Backend selection was correct in
   the serve log: **MARLIN** MXFP4 MoE backend + **TRITON_ATTN**, weights loaded clean (440 s, 60.77
   GiB), reached `MoEPrepareAndFinalizeNoDPEPModular` — then the container still died (**exit 255**).
   So the failure is **not** purely the cudagraph phase; the MXFP4 MoE finalize / runtime also
   over-commits the unified pool on this box.

## Why we stopped
gpt-oss-120b never served a single benchmarkable session here. Every attempt either wedges the host
(reboot-level, not container-scoped like the known c32 hang) or exits during MoE finalize. The
weights *fit*, but the MXFP4-MoE runtime working set on top of them doesn't leave the OS enough of
the shared pool to stay alive. This is a memory-management mismatch between this MXFP4 MoE path and
the GB10 unified-memory constraint, not a config we can tune our way out of with the current image.
Two other 120B-class MoEs *do* serve here (Nemotron-3-Super-120B-A12B at util 0.85, Qwen3-Next-80B),
so the box is capable — gpt-oss's MXFP4/Marlin path specifically is the problem.

## If revisited (do NOT re-run as-is)
- **Gate on a vLLM image bump first.** The MXFP4-on-Blackwell path is young (Aug-2025 launch needed a
  special `0.10.1+gptoss` wheel; mainlined only by 0.23.0). A newer image may add a non-Marlin MXFP4
  MoE backend or fix the post-load allocation. Re-test the MoE backend oracle + memory profile then.
- Try capping the cudagraph capture size (the auto-1024 bump) instead of full `--enforce-eager`, and
  pushing util **lower** (0.55) to give the MoE finalize more headroom — but only after an image that
  doesn't already die at MoE finalize under eager.
- Consider SGLang as the backend for gpt-oss specifically — it's how gpt-oss-120b is most commonly
  served on DGX Spark in the wild; out of scope for this vLLM-first project but the right comparison.
