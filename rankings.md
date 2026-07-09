# Model rankings — chat throughput + accuracy (GB10 node #1)

Promoted-winner throughput per model, **chat shape (512/256)**, ranked by **c16** (the tuned objective),
with accuracy gates appended. tok/s = GuideLLM `output_tokens_per_second.successful.mean`, per-level
isolation, N=3 median (or the finalize full-sweep characterization row). Node `gb10-1988a9714b4e`
(NVIDIA GB10, sm_121, ~121.6 GiB unified LPDDR5X), vLLM 0.23.0. **c1** = single-stream latency
sentinel; **c16** = batched objective.

> Decode on GB10 is memory-bandwidth-bound (LPDDR5X ≪ HBM), so absolute tok/s runs low vs discrete
> GPUs and scales with *active* bytes/token (quant + active params), not total size. Don't compare these
> to HBM GPUs naively.

| # | Model | Class · quant | Winner (lever) | c1 | **c16** | c32 | mmlu | gsm8k | mmlu_pro |
|---|-------|---------------|----------------|----|---------|-----|------|-------|----------|
| 1 | RedHatAI/Qwen3-8B-NVFP4 | 8B dense · NVFP4 | kvfp8 (fp8 KV) | 41.9 | **563.2** | 950.6 | 71.0 | 87.6 | — |
| 2 | WeiboAI/VibeThinker-3B | 3B dense · BF16 | baseline | 29.8 | **485.1** | 852.7 | — | — | — ◆ |
| 3 | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | 35B/3B MoE · NVFP4 | baseline (MTP-on) | 56.4 | **340.6** | 470.7 | 78.2 | 90.0 | — |
| 4 | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | 80B/3B MoE · NVFP4 | mtp-n1 (MTP) | 56.2 | **295.1** | — | 84.3 | 81 ‡ | — |
| 5 | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | 80B/3B MoE · NVFP4 | mtp-n1 (MTP) | 50.8 | **266.7** | 362.5 | 84.9 | 96.0 | 71.9 |
| 6 | RedHatAI/Qwen3-Coder-Next-NVFP4 | 80B/3B MoE · NVFP4 | baseline (MTP stripped) | 37.1 | **220.1** | 286.7 | 81.8 | 94.2 | 70.1 ★ |
| 7 | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | 75B/9B hybrid MoE · NVFP4 | mtp-n1 (MTP) | 29.5 | **173.1** | 240.4 | 83.7 | 95.0 | 71.9 † |
| 8 | unsloth/Qwen3.6-27B-NVFP4 | 27B dense mm · NVFP4 | mtp-n1 (MTP) | 16.8 | **161.5** | — | 84.3 | 98.0 | 71.6 |
| 9 | RedHatAI/gemma-4-31B-it-NVFP4 | 31B dense mm · NVFP4 | baseline | 10.5 | **109.0** | 136.7 | 41.2 ✗ | 73.0 | 48.4 |
| 10 | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 120B/12B MoE · NVFP4 | mtp-n1 (MTP) | 22.4 | **93.7** | 120.5 | 85.8 | 61.0 | 75.0 |

### Accuracy notes
- **mmlu** = loglikelihood, thinking-ON (the in-loop knowledge reference). **gsm8k** + **mmlu_pro** =
  generative; reasoning models are evaluated thinking-OFF (thinking-ON depresses generative — e.g. the
  35B's gsm8k went 40→90 with thinking off). Values are finalize full-eval where available, else LIMIT=100.
- **✗ gemma mmlu=41.2 is a loglikelihood ARTIFACT** (Gemma BOS / prefix-LM bidirectional attn /
  logit-softcap on NVFP4), **not** a real quality signal — read its **mmlu_pro 48.4** + **gsm8k 73** instead.
- **‡ Qwen3-Next-Thinking gsm8k = 81 (flexible-extract).** strict-match was 25–32 — a format artifact of
  the always-on `<think>` CoT, not a quality drop. MTP is greedy-lossless (baseline gsm8k flexible = 81 too).
- **◆ VibeThinker is a competition-math model** → **AIME24 90.0 / AIME25 86.67** (Pass@1, temp 1.0,
  reproducing the paper's frontier). gsm8k/mmlu are n/a for it.
- **★ Coder models also report code gates:** Qwen3-Coder-Next **HumanEval 69.5 / MBPP 77.0**;
  Qwen3-Next-80B-Instruct **HumanEval 40.9 / MBPP 80.8**.
- **† Puzzle-75B gsm8k/mmlu_pro shown = baseline think-off (95 / 71.9)** — the lossless-representative
  quality (mmlu-LL confirms MTP lossless: 83.51→83.67). The mtp-n1 winner *measured* 91 / 69.2 at
  LIMIT=100, within batched-serving noise (same pattern as the Super row). Unusually, `nemotron_h_mtp`
  loglikelihood WORKS (valid prompt_logprobs) — most spec-decode configs NaN it.
- Per-model raw rows + think-on/off variants live in each
  `results/gb10-1988a9714b4e/<org>/<model>/accuracy.tsv` and `logbook.md`.

### Throughput notes
- **MTP is the dominant throughput lever** where the head survives quantization: **Qwen3.6-27B +31.7%
  c16 (the largest in the project** — 85-94% acceptance, dense model), Nemotron-120B +14.9% (93.7 vs 73),
  Qwen3-Next-80B Instruct +12.4% / Thinking +14.9%, **Nemotron-Labs-3-Puzzle-75B +12% (native
  nemotron_h_mtp, n=1, 90-93%/77% accept c1/c16; n=2 fails smoke, n=4 poor per HF disc #1)**. Qwen3.6-35B
  keeps MTP on in its baseline (mtp-off −14.5%). Qwen3-Coder-Next's NVFP4 build **stripped** the MTP head,
  so no lever. (qwen3_5_mtp loads on stock 0.23.0; qwen3_next_mtp needed patches; nemotron_h_mtp is native.)
- **enforce-eager is MEMORY-MANDATORY for NemotronH-Puzzle on GB10:** its loader spikes ~160 GB at
  torch.compile/CUDA-graph capture (HF disc #1) → OOMs the 121.6 GiB box; `--enforce-eager` +
  expandable_segments drop the peak to 99.5 GB (zero swap). Costs CUDA graphs but is the only fit without
  swap. (Distinct from gpt-oss-120b, whose over-commit was NOT avoidable — see Not ranked.)
- **Smaller active footprint → faster:** the 8B dense (NVFP4) and 3B dense (BF16, compute-bound) top the
  chart; the 120B/A12B sits last (12B active = most bytes/token). c1 tracks active-param byte cost.
- **c32** is the full-sweep value where the finalize sweep ran; Qwen3-Next-Thinking promoted on N=3 c1/c16
  (full both-shape sweep skipped by choice) → c32 not measured.

### Not ranked
- **openai/gpt-oss-120b** (117B/5.1B MoE, MXFP4) — **ABANDONED**, never served: MXFP4 MoE finalize
  over-commits GB10 unified memory → host reboot, every config. See
  `results/gb10-1988a9714b4e/openai/gpt-oss-120b/logbook.md`.
