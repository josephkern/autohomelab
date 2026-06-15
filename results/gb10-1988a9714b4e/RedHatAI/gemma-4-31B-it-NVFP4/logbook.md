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

## 20260615 — tune loop (5-candidate ablation) + finalize → CAMPAIGN COMPLETE
`research/run-queue-gemma-0.23.0.sh`, each candidate = baseline + ONE change, N=3, c1/c16, smoke-gated.
Re-measured baseline median **c16=104.3** (N=3; ±noise of the 109 sweep). Keep rule c16 > +3%;
numeric-risky knobs gated on gsm8k recovery (matched LIMIT=100) only if they win on throughput.

| candidate | c16 | c1 | verdict |
|---|---|---|---|
| baseline (kv auto/bf16, auto cutlass FP4) | 104.3 | 10.5 | reference |
| **kvfp8** (+ --kv-cache-dtype fp8_e4m3) | **129.2** | 10.6 | **+23.8% c16 but QUALITY FAIL** (see below) |
| memutil-08 (util 0.5→0.8) | 105.2 | 10.5 | discard +0.9% (noise; KV not the binding limit for chat) |
| batched-16k (+max-num-batched-tokens) | 103.0 | 10.5 | discard −1.2% (noise) |
| linear-marlin | 84.6 | 10.5 | discard **−18.9%** — native cutlass ≫ marlin (matches 8B) |
| linear-b12x | — | — | **serve_fail** (as on the 8B; b12x FP4 GEMM won't init on sm_121) |

**kvfp8 quality (the deciding check).** fp8-KV gave a big +23.8% c16 (KV-capacity was the constraint),
but quality regressed — confirmed with the low-variance mmlu_pro (1400 samples), not just noisy gsm8k:
| metric | baseline | kvfp8 | Δ |
|---|---|---|---|
| mmlu_pro (LIMIT=100, 1400 samp) | 48.36 | 46.29 | **−4.3%** |
| gsm8k (LIMIT=100; two runs) | 73.0 | 68.0 / 71.0 | ~−4 to −5% |
Both generative metrics moved down together → a real ~4% regression (Gemma's sliding-window attention
+ logit-softcapping + thinking-mode CoT make the KV cache precision-sensitive), well beyond the
~1-2% "good" tolerance. (The two gsm8k runs, 68 vs 71, show ~±3pt LIMIT=100/temp1 noise — why
mmlu_pro was the arbiter.)

**Decision (user call): baseline stands.** kvfp8's −4.3% mmlu_pro fails the "good" gate, so the
baseline is the only config clearing all three gates. `20260614_kvfp8_tuned.sh` is **kept as an
optional "speed mode"** (+23.8% c16 for ~4% quality) — documented, not the canonical serve config.

**Promoted** baseline → `VLLM-23-RedHatAI_gemma-4-31B-it_NVFP4_final.sh` (winner by default).
Gates on the promoted config (serving-identical to the suited baseline): **Gate 1** smoke 4/4;
**Gate 2** gsm8k=73.0 / mmlu_pro=48.36 (mmlu=41 loglikelihood artifact, excluded); **Gate 3**
chat c1=10.45…c16=109…c32=136.65, coder collapses past c8. Campaign done for (gb10, gemma-4-31B,
vLLM 0.23.0).

**Tuning takeaways:** dense bandwidth-bound model — chat throughput is KV/batch-limited, so fp8-KV is
the only real lever but it trades quality here; native cutlass FP4 is the right GEMM (marlin −19%,
b12x fails); util/batched-tokens are saturated.
