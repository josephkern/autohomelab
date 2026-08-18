# Logbook — unsloth/Qwen3.8-27B-NVFP4 on gb10-1988a9714b4e

Campaign branch: `autoresearch/qwen3.8-27b-nvfp4`.
Objective: **median c16 tok/s, chat(512/256)**, N=3, KEEP rule = **>3%** over current best.

## Why this campaign exists

A **controlled checkpoint comparison** against the completed `Inferact/Qwen3.8-27B-NVFP4` campaign.
Same base model — `Qwen/Qwen3.8-27B`'s config matches both checkpoints on every field (hidden 5120,
64 layers, vocab 248320, heads 24/4, head_dim 256, intermediate 17408, linear 16/48,
`full_attention_interval` 4, `mtp_num_hidden_layers` 1) — different NVFP4 quantization. The baseline
runbook differs from Inferact's by **exactly two lines** (`MODEL`, `MODEL_REVISION`), verified by
diff, so the baseline delta isolates the checkpoint.

## Environment (AGENTS rule #3)

| item | value |
|---|---|
| node_fp | `gb10-1988a9714b4e` (NVIDIA GB10, sm_121, aarch64, ~121.6 GiB unified LPDDR5X, 273 GB/s) |
| driver | 580.173.02 · CUDA 13.0 |
| vLLM | **0.27.1** — `vllm/vllm-openai@sha256:0a51ea5b4ae2…` (same image as the Inferact campaign) |
| GuideLLM | 0.6.0 |
| model | `unsloth/Qwen3.8-27B-NVFP4`, revision `7d6f8d4d72f56b92b3cdbf22f156b90e1bab0108` |
| weights | 23.42 GB on disk (`model.safetensors` 22.57 + `model_mtp.safetensors` 0.85) |
| baseline | `runbooks/unsloth/Qwen3.8-27B-NVFP4/baseline.sh` (config_hash `8cfcfcac`) |

## Session 1 — 20260818: baseline, all three gates green

| gate | unsloth baseline | Inferact baseline | delta |
|---|---|---|---|
| 1 works | **PASS** (4/4) | PASS | == |
| 2 gsm8k (n=100, think-off) | 95.0 | 97.0 | −2.0 |
| 2 mmlu (n=100, think-on, loglikelihood) | 79.89 | 82.61 | −2.72 |
| 2 mmlu_pro (n=100, think-off) | **70.43** | 67.79 | **+2.64** |

**Quality: no evidence of a lossier checkpoint.** All three deltas sit inside the ±4 pt binomial SE
of a 100-sample eval, and they do not point the same way (two down, one up). A genuinely lossier
quantization would show a consistent deficit; a mixed ±2.7 is what noise looks like. Not the same as
proving equivalence — that needs the FULL evals at finalize.

### Throughput — the lighter checkpoint wins at every level, in both shapes

| level | chat Inferact | chat unsloth | Δ | coder Inferact | coder unsloth | Δ |
|---|---|---|---|---|---|---|
| c1 | 10.34 | 13.60 | +31.5% | 12.62 | 14.23 | +12.8% |
| c4 | 37.49 | 45.03 | +20.1% | 32.21 | 40.54 | +25.9% |
| c8 | 68.92 | 77.86 | +13.0% | 54.65 | 73.13 | +33.8% |
| c16 | 116.63 | **136.36** | **+16.9%** | 82.98 | **102.83** | **+23.9%** |
| c32 | 177.34 | 205.42 | +15.8% | 102.02 | 137.32 | **+34.6%** |

Counts verified valid (chat 12/46/72/113/136; coder 7/22/40/57/75 successful — c1 on the coder shape
is inherently sample-limited at ~12 max per 600 s stage, but 0 incomplete, so it is a true measure).

### The gain is NOT explained by size — the bytes-only model is falsified

Predicted from the 8.3% weight difference (25.53 → 23.42 GB): c1 ≈ **11.27**. Measured: **13.60**,
i.e. **1.21× the prediction**. And the naive roofline is not merely wrong, it is *impossible*:

    23.42 GB × 13.60 tok/s = 318.5 GB/s = 117% of the GB10's 273 GB/s peak

So "every weight is read every token" is FALSE for these checkpoints. Both are
`Qwen3_5ForConditionalGeneration` (multimodal): the **vision tower is resident but never read during
text decode**, and the MTP head is not read without a spec config. Backing out the real text-decode
footprint (≤20.1 GB for unsloth ⇒ ≥2.5 GB is vision), Inferact's text path is ~22.2 GB ⇒ ~229 GB/s
≈ **84% of peak, not the 96.7% previously claimed**. There was headroom; this checkpoint claims it.

**Correction to the campaign record:** earlier notes (and the 27B logbook) state our baseline sat at
~93–97% of peak bandwidth with "no engine headroom at c1." That figure counted the vision tower and
MTP head as if read per token. The corrected figure is ~84%.

### Mechanism: a different kernel path, not just a smaller file

Serve log for this checkpoint:

    Selected CutlassFP8ScaledMMLinearKernel for CompressedTensorsW8A8Fp8
    Using FlashInferCutlassNvFp4LinearKernel for NVFP4 GEMM

It is a **mixed FP8 + NVFP4** build running the FlashInfer Cutlass FP4 GEMM (with an autotuner pass
over 16 `fp4_gemm` profiles). Our earlier NVFP4 campaign recorded `MarlinNvFp4LinearKernel` — the
dequantize-through-Marlin fallback on SM121. **NOT YET CONFIRMED** which kernel the Inferact
checkpoint selects; that is a one-line grep of the serve log next time it runs, and it should be
done before the kernel-path story is treated as established.

### The two levers pull in opposite directions across concurrency

MTP's benefit **decays** with batch (Inferact coder: +54% at c1 → **−5% at c32**) — it is a
bandwidth-bound win, and bandwidth stops binding as the batch fills. The checkpoint/kernel win
**grows** with batch (coder: +12.8% at c1 → **+34.6% at c32**) — a compute-bound win, and compute is
what binds at high concurrency. They should therefore **stack** rather than compete.

Consequence worth flagging: **the unsloth baseline already beats the promoted Inferact final on the
long shape** — coder c16 102.83 vs 88.56 (**+16.1%**), coder c32 137.32 vs 96.88 (**+41.7%**) — with
no tuning at all. On chat the promoted final still leads (171.12 vs 136.36, −20.3%), but MTP has not
been applied to this checkpoint yet.

## Status

Baseline validated = current best (chat c16 **136.36**). Proceeding to program.md §2 tune loop.
First candidate is MTP: Inferact's optimum was n=3, but depth is checkpoint-dependent and this build
runs a different FP4 GEMM, so acceptance and per-draft cost must be **re-derived, not inherited**.
