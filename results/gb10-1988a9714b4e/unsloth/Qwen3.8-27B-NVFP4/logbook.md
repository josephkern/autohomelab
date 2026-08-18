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

## Session 1 (cont.) — 20260818: wave 1, MTP depth bracket

Reference = the baseline measured this session, chat c16 **136.36**. KEEP threshold >3% ⇒ >140.5.

| candidate | c16 med | c1 med | vs baseline | vs promoted Inferact final (171.12) | verdict |
|---|---|---|---|---|---|
| baseline | 136.36 | 13.60 | — | −20.3% | — |
| MTP n=2 | 188.34 | 23.15 | +38.1% | +10.1% | keep-worthy, beaten |
| **MTP n=3** | **208.86** | 25.64 | **+53.2%** | **+22.1%** | **KEEP — winner** |
| MTP n=4 | *unstable* | 28.99 | — | — | **DISCARD** |

**The two levers stack, and MORE than additively — which contradicts the prediction.** Checkpoint
+16.9%, then MTP +53.2% on top ⇒ **+79.1% over the Inferact baseline** at c16 (116.63 → 208.86).

I predicted MTP would be worth **less** on this checkpoint, reasoning that MTP buys back
bandwidth-bound time and the faster FP4 GEMM path leaves less bandwidth-starvation to recover.
Measured the opposite: MTP is worth **+53.2%** here against **+43.8%** on Inferact at its own tune-loop
optimum (+46.7% at finalize). The prediction was backwards.

The likely reason is that MTP's payoff scales with how cheaply the *verify* pass runs, not only with
how starved decode is: a faster GEMM makes each speculative verification cheaper, so more drafted
tokens pay off per unit time. That is a hypothesis fitted after the fact and is NOT established —
the acceptance-rate data that would test it (per-request `draft acceptance` lines in the vLLM log)
was never captured for either campaign. Recorded as an open question, not a conclusion.

### MTP n=4 is INTERMITTENTLY FATAL at c16 — discarded on stability, not speed

Three attempts, two crashes:

| attempt | c16 | outcome |
|---|---|---|
| wave 1 queue | 449358.18 (bogus) | **crash** |
| ad-hoc retest | 205.50 | survived |
| N=3 run | 1992.87 (bogus) | **crash** |

Both crashes share one signature: the c16 stage records ~16 "successful" against **~110,000 errored**
requests, and `gpu_metrics.csv` shows the container dying mid-stage (sys_used 72 GB → 7 GB, SM clock
2398 → 208 MHz, power 10.7 W → 3.7 W). **c1 on the same serve is healthy every time** (ok=20,
errored=0). So the failure is concurrency-triggered, not a bad config that fails to serve.

The bogus tok/s values arise because the handful of "successful" requests return in ~0 s against a
dead endpoint, so `successful.mean` explodes. **Both rows are marked `crash` with `tps_c16=na`** —
left in place as the record, but they must never be read as measurements. This is the third distinct
instance today of a broken run producing a confident-looking number rather than an error.

**Intermittent is worse than deterministic**: n=4 passed a spot check between two failures, so a
single validation run would have promoted an unstable config. The surviving run measured 205.50,
*below* n=3's 208.86, so n=4 loses on speed as well — it is discarded on both grounds and no further
depth was explored.

**Crash cause NOT captured.** The container was gone before it could be inspected on both failures,
and the one run with `docker logs -f` attached did not crash. Recorded as an open question; a
dedicated repro with log capture would be needed to file this upstream.

### Depth optimum is batch-dependent — third independent observation

n=4 has the best c1 (**28.99**, +13% over n=3) while losing at c16. Same pattern as the Inferact MTP
bracket (n=4 best c1, n=3 best c16) and FF711 on llama.cpp (best c1 at depth 3, best c16 at depth 1).
The c16 objective systematically selects a **shallower** draft than a latency-first deployment would.
Worth carrying into the final config note, since the promoted artifact is tuned for c16 throughput
while interactive traffic is effectively c1 — but n=4 is not available as the latency option here,
because it is the unstable one.

**Bracket closed.** n=3 is an interior optimum (n=2 below it, n=4 below it and unstable), so no
extension is warranted in either direction.

## Session 1 (cont.) — 20260818: wave 2 — zero for three

Reference = MTP n=3 at **208.86**. KEEP threshold >3% ⇒ >215.1.

| candidate | c16 med | verdict |
|---|---|---|
| `--max-num-scheduled-tokens 8192` | — | **serve_fail — invalid flag value (my error)** |
| `qwen3_5_mtp` (n=3) | 206.94 | **DISCARD** (−0.9%, flat) |
| DSpark n=7 (RadixArk drafter) | — | **serve_fail — method is DeepSeek-V4-only** |

Wave 2 found nothing. Same shape as the Inferact campaign, whose wave 2 was also a clean sweep of
nothing. **On both checkpoints MTP depth is the only lever that has ever mattered**; everything
tested downstream of it has been noise or breakage.

### `qwen3_5_mtp` is not a better path — question closed

206.94 vs 208.86 (−0.9%, inside the ~4% run-to-run spread seen on n=3). The arch-specific method
behaves as the generic `mtp` on this model. Recorded so nobody re-opens it.

### `--max-num-scheduled-tokens 8192` is invalid here — and the "loose thread" never existed

```
VllmConfig received max_num_scheduled_tokens but it does not have enough slots to support the
speculative decoding settings. It should be greater by at least 0, but got
max_num_batched_tokens=2048 and max_num_scheduled_tokens=8192
```

The constraint is `max_num_scheduled_tokens ≤ max_num_batched_tokens`, and **with spec-decode active
`max_num_batched_tokens` is itself 2048**, so 8192 is invalid by construction.

**CORRECTION to the Inferact logbook's "one loose thread left".** That note claimed the startup
warning names `max_num_scheduled_tokens` and that raising `--max-num-batched-tokens` (wave 2 there,
16384, +0.11%) "never actually tested the quantity the warning names". That reading was backwards —
the warning says *"consider increasing **max_num_batched_tokens**"*, which is exactly what that
experiment did. The thread was already closed and came back flat: **the scheduler budget is not the
constraint.** No further work is warranted on this axis for either checkpoint.

### vLLM's `method: dspark` is DeepSeek-V4-specific, NOT a generic drafter loader

```
File "vllm/models/deepseek_v4/nvidia/dspark.py", line 72, in __init__
    self.hc_mult = config.hc_mult
AttributeError: 'Qwen3Config' object has no attribute 'hc_mult'
```

It loads NVIDIA's DSpark implementation for **DeepSeek-V4** and expects a config carrying `hc_mult`;
`RadixArk/Qwen3.8-27B-DSpark` ships a `Qwen3Config`. Same name, different mechanisms. The drafter's
own card prescribes **SGLang**, which is consistent.

**Bearing on the 0xBakeer writeup:** its published serve command pairs vLLM **0.27.1** with
`{"method":"dspark", ...}` and a "Qwen3.8-27B-DSpark, 5 layers, 2.6 GB" drafter — which matches
RadixArk exactly (we downloaded it: 2.6 GB). We ran that combination on stock 0.27.1 and it fails at
model init. **That serve command is not reproducible as published**, absent an unpublished drafter or
a patched vLLM. Its measured *numbers* remain untested by us either way; this refutes the recipe, not
the results. The general lesson from that writeup — accepted LENGTH is the currency, not acceptance
rate — still stands and is what motivated the n=4 probe.

### Byproduct: the engine-core CPU question, answered with a stack

`py-spy` on a healthy MTP n=3 serve mid-c16-bench, 3/3 samples identical: the engine core sits in
**spec-decode draft attention-metadata construction** (`build_for_drafting` →
`build_per_group_and_layer_attn_metadata` → flashinfer `build` → `seq_lens_cpu`), *not* in
`get_output()` and not spin-waiting on the GPU. That is depth-dependent per-step CPU work.

Consequences: **`--async-scheduling` is a live candidate** (previously dismissed on a spin-wait
theory that the stack falsified), and there is now a testable mechanism for the depth turnover
(n=4 wins c1 28.99 vs 25.64, loses c16) that does not require acceptance decay. Full method +
control stack: `research/upstream/vllm-43885-gb10-wedge.md`.

## Status

Winner unchanged: **`20260818_mtp-n3_tuned.sh`, chat c16 208.86** (+53.2% over baseline, +22.1% over
the promoted Inferact final). Tune loop has one untested candidate left worth running
(`--async-scheduling`); otherwise ready for program.md §3 finalize.
