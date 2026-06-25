# Model rankings — chat throughput (GB10 node #1)

Promoted-winner throughput per model, **chat shape (512/256)**, ranked by **c16** (the tuned objective).
tok/s = GuideLLM `output_tokens_per_second.successful.mean`, per-level isolation, N=3 median (or the
finalize full-sweep characterization row). Node `gb10-1988a9714b4e` (NVIDIA GB10, sm_121, ~121.6 GiB
unified LPDDR5X), vLLM 0.23.0. **c1** = single-stream latency sentinel; **c16** = batched objective.

> Decode on GB10 is memory-bandwidth-bound (LPDDR5X ≪ HBM), so absolute tok/s runs low vs discrete
> GPUs and scales with *active* bytes/token (quant + active params), not total size. Don't compare these
> to HBM GPUs naively.

| # | Model | Class | Quant | Winning config (lever) | c1 | **c16** | c32 |
|---|-------|-------|-------|------------------------|----|---------|-----|
| 1 | RedHatAI/Qwen3-8B-NVFP4 | 8B dense | NVFP4 | kvfp8 (fp8 KV) | 41.9 | **563.2** | 950.6 |
| 2 | WeiboAI/VibeThinker-3B | 3B dense | BF16 | baseline (compute-bound) | 29.8 | **485.1** | 852.7 |
| 3 | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | 35B/3B MoE | NVFP4 | baseline (MTP-on) | 56.4 | **340.6** | 470.7 |
| 4 | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | 80B/3B MoE | NVFP4 | mtp-n1 (MTP) | 56.2 | **295.1** | — |
| 5 | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | 80B/3B MoE | NVFP4 | mtp-n1 (MTP) | 50.8 | **266.7** | 362.5 |
| 6 | RedHatAI/Qwen3-Coder-Next-NVFP4 | 80B/3B MoE | NVFP4 | baseline (MTP stripped) | 37.1 | **220.1** | 286.7 |
| 7 | RedHatAI/gemma-4-31B-it-NVFP4 | 31B dense (mm) | NVFP4 | baseline | 10.5 | **109.0** | 136.7 |
| 8 | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 120B/12B MoE | NVFP4 | mtp-n1 (MTP) | 22.4 | **93.7** | 120.5 |

### Notes
- **MTP is the dominant throughput lever** where the head survives quantization: Nemotron-120B +14.9%
  c16 (mtp-n1 93.7 vs baseline 73), Qwen3-Next-80B Instruct +12.4% / Thinking +14.9%. Qwen3.6-35B keeps
  MTP on in its baseline (mtp-off −14.5%). Qwen3-Coder-Next's NVFP4 build **stripped** the MTP head, so
  no lever — it sits below its Instruct sibling despite identical arch.
- **Smaller active footprint → faster:** the 8B dense (NVFP4) and 3B dense (BF16, compute-bound) top the
  chart; the 120B/A12B sits last (12B active = most bytes/token). c1 tracks active-param byte cost.
- **c32 column** is the full-sweep value where the finalize sweep ran; Qwen3-Next-Thinking promoted on
  N=3 c1/c16 (full both-shape sweep skipped by choice) → c32 not measured.
- Per-model coder-shape (4096/1024) numbers and quality gates live in each
  `results/gb10-1988a9714b4e/<org>/<model>/logbook.md`.

### Not ranked
- **openai/gpt-oss-120b** (117B/5.1B MoE, MXFP4) — **ABANDONED**, never served: MXFP4 MoE finalize
  over-commits GB10 unified memory → host reboot, every config. See
  `results/gb10-1988a9714b4e/openai/gpt-oss-120b/logbook.md`.
- **unsloth/Qwen3.6-27B-NVFP4** (27B dense mm, NVFP4, MTP) — **in progress** (download stalled at 7.6 GB).
