# Logbook — RedHatAI/gemma-4-31B-it-NVFP4 on gb10-1988a9714b4e

DENSE 31B, NVFP4 (compressed-tensors), multimodal arch (`Gemma4ForConditionalGeneration`) served
TEXT-ONLY. Hybrid attention (sliding-window 1024 + full every 6th layer, 60 layers). Fresh baseline
(no old-homelab prior-art). First model run under the **standard test suite** (`scripts/suite.sh`).
Data rows in `results.tsv` / `accuracy.tsv`; raw bundles in `data/`.

## Environment
- node `gb10-1988a9714b4e` (GB10 sm_121, aarch64, ~121.6 GiB unified, driver 580.159.03, CUDA 13.0)
- backend `vllm/vllm-openai@sha256:6d8429e…` = **vLLM 0.23.0** (torch 2.11+cu130)
- model revision `c4905986988f1406d7d7d80200d81099977a9123`
- weights 21.67 GB (NVFP4); served: NVFP4 GEMM via `FlashInferCutlassNvFp4LinearKernel`
  (linear_backend=auto on 0.23.0 — native FP4, NOT marlin), kv-dtype auto (bf16), chunked+prefix
  caching, reasoning+tool parser gemma4, `--limit-mm-per-prompt {"image":0}` (skip vision encoder),
  sampling temp1/top_p0.95/top_k64 (generation_config).

## 20260614 — baseline (standard suite, vLLM 0.23.0)
Serves clean (~340s load). **Gate 1 smoke: PASS 4/4** (chat / JSON / tool-call / reasoning).
Caught + fixed at setup: the HF card's `--limit-mm-per-prompt image=0` shorthand is rejected on
0.23.0 (needs JSON `'{"image":0}'`).

**Gate 3 throughput (full sweep, tok/s):**
| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat (512/256)   | 10.45 | 37.33 | 64.48 | **109** | 136.65 |
| coder (4096/1024)| 10.25 | 25.64 | 34.79 | 23.04 | 3.02 |

Absolute tok/s is ~3x below the Qwen "35B-A3B" — expected: this is a **dense 31B** (all params
active/token) vs that model's MoE (~3B active/token). c1≈10.4 ≈ the bandwidth ceiling (21.67 GB
weights ÷ ~273 GB/s ≈ 12.6 tok/s) → decode is hard memory-bandwidth-bound. The **coder shape
collapses at c16/c32** (23→3): 5120-token sequences exhaust the 90,461-token KV cache (max
concurrency ~11x at 8192) → heavy preemption. KV capacity, not compute, is the coder-shape limit →
fp8-KV / higher util / lower max-model-len are the levers.

**Gate 2 quality (LIMIT=100):**
- gsm8k = **73.0** (generative, 5-shot) — healthy.
- mmlu = **41.19** ⚠️ — *loglikelihood artifact, DISCARD*. A 31B should score ~75-80; gsm8k healthy
  + smoke OK ⇒ the model isn't broken. Root cause is the loglikelihood path on this arch (Gemma BOS
  sensitivity / prefix-LM bidirectional attention — startup log literally tags it "prefix-LM model"
  / `final_logit_softcapping=30.0` on NVFP4). See AGENTS.md follow-up.
- mmlu_pro = **48.36** (generative, custom-extract) — real, non-floored signal confirming the model
  works. Depressed vs the card's 84.07 because the card evaluated **thinking-OFF + greedy**, while we
  serve **thinking-ON + temp1 sampling** (the repo-wide eval-bleed issue). (Parser bug fixed: the
  task's `exact_match,custom-extract` key wasn't recognized → recorded sample_len 140000; corrected
  to 48.36 + eval.sh patched.)

**Quality gate for the tune loop:** use **relative recovery on gsm8k + mmlu_pro at matched LIMIT=100**
(baseline: gsm8k=73.0, mmlu_pro=48.36). **Do NOT gate on standard mmlu** (loglikelihood, unreliable
here). Numeric-risky knobs must stay within ~1-2% of these.

## Next — tune loop
Dense NVFP4, bandwidth-bound, KV-capacity-limited at high concurrency. Candidate queue (one change
each vs baseline, objective = median c16 chat = 109): **kv-cache-dtype fp8_e4m3** (the 8B win —
doubles KV → bigger batches; quality-risky→eval), **gpu-mem-util 0.5→0.8** (more KV pool; card
suggested 0.90), **max-num-batched-tokens 16384** (+chunked prefill), **linear-backend marlin** and
**flashinfer_b12x** vs auto/cutlass (GEMM path; quality-risky→eval). Then validate + promote
`VLLM-23-RedHatAI_gemma-4-31B-it_NVFP4_final.sh`.
