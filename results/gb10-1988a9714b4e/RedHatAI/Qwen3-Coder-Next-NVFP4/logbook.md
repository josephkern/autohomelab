# Logbook — RedHatAI/Qwen3-Coder-Next-NVFP4 (node gb10-1988a9714b4e)

## Environment (AGENTS rule #3)
- node: GB10 (DGX Spark), sm_121, aarch64, ~121.6 GiB unified LPDDR5X; driver 580.159.03, CUDA 13.0
- vLLM: **0.23.0** — image `vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f`
- GuideLLM 0.6.0; lm-eval harness for Gate 2
- model revision: `27a8f16f463b9a13c91c332c40cf93e09717347e`
- branch: `autoresearch/qwen3-coder-next`

## Model
`Qwen3NextForCausalLM` / `qwen3_next` — hybrid Gated-DeltaNet linear-attention + sparse MoE,
80B-A3B class, **45 GB NVFP4** (compressed-tensors) weights, 262K native ctx, 48 layers
(3:1 linear:full-attn → 12 full-attn layers), 512 experts / 10-per-tok + shared expert.
Non-thinking coder: **qwen3_coder** XML tool parser, no reasoning parser, sampling top_p0.95/top_k40.
vLLM 0.23.0 supports the arch natively (GDN Triton/FLA prefill kernel; MoE auto → **FLASHINFER_CUTLASS**;
full-attn → FLASH_ATTN; cudagraphs FULL_AND_PIECEWISE).

## 2026-06-20 — Baseline (cfg 97153804) — GREEN, all three gates. Current best.
Runbook `baseline.sh`; gpu-mem-util 0.50 (weights 44 GB fit, KV room for bench shapes); max-model-len 8192.
- **Gate 1 smoke: PASS 3/3** (chat, JSON, tool-call; reasoning skipped — non-thinking).
- **Gate 2 quality:** gsm8k=**95.0** (think-off), mmlu=**83.81** (loglikelihood, think-on, healthy — no
  Gemma-style LL artifact here), mmlu_pro=**70.07** (think-off). limit=100.
- **Gate 3 throughput** (full sweep, load 447 s):
  | shape | c1 | c4 | c8 | c16 | c32 |
  |---|---|---|---|---|---|
  | chat(512/256)  | 37.05 | 108.78 | 158.41 | **220.1** | 286.65 |
  | coder(4096/1024)| 36.52 | 87.79 | 111.2 | **133.91** | 119.83 |
  chat scales past c16 (+30% to c32); coder dips at c32 (bandwidth saturation). No GB10 hang this run.

## Tune loop (objective = median c16 chat, N=3, KEEP if >+3%)

### cand #1 — `20260620_ngram-spec_tuned.sh` — **DISCARD** (−34.6% c16)
+ `--speculative-config '{"method":"ngram","num_speculative_tokens":5,"prompt_lookup_min":2,"prompt_lookup_max":5}'`.
- **MTP not possible on this checkpoint:** RedHatAI's NVFP4 conversion **stripped the MTP head**
  (config has no `num_nextn_predict_layers`; 0 nextn/predict tensors across 296,151 weights; layers 0–47
  only). So `method:"mtp"` would serve_fail; ngram is the only model-free spec-decode path here.
- Serves fine on qwen3_next, smoke 3/3 (tool-call still parses under spec-decode). But vLLM warns it
  **disables async scheduling** and **caps `max_num_scheduled_tokens=2048`** under ngram.
- N=3 median **c16=143.95 (−34.6% vs 220.1)**, c1=24.93 (−32.7%). Regression hits even c1 → pure
  drafting overhead with ≈0 acceptance. Root cause: our **GuideLLM synthetic data is random tokens**
  (no n-gram repetition to accept) **+ the 2048 scheduler cap** throttling batched throughput.
- Verdict: discard as a default serve config on our objective. Would still help REAL repetitive coding
  traffic, but our synthetic bench can't reward it and the scheduler cap actively hurts here.
  (spec-decode ⊥ loglikelihood; greedy-lossless so quality unaffected — no separate eval needed.)

### cand #2 — `20260620_mnbt-16384_tuned.sh` — **DISCARD** (+1.1% c16, within noise)
+ `--max-num-batched-tokens 16384` (default ~8192). Smoke 3/3.
- N=3 (222.58, 218.08, 222.9) median **c16=222.58 (+1.1% vs 220.1)**, c1=37.0 (flat). Below the +3%
  keep floor → discard. Expected: the knob co-schedules prefill, but this model's c16 is
  decode-bandwidth-bound, not prefill-limited, so batched throughput barely moves.

### cand #3 — `20260620_gpumem-0p8_tuned.sh` — **DISCARD** (+0.2% c16, neutral)
+ `--gpu-memory-utilization 0.5 -> 0.8`. Smoke 3/3; box stayed stable (no OOM/crash on the unified pool).
- N=3 (220.6, 218.89, 221.24) median **c16=220.6 (+0.2% vs 220.1)**, c1=37.23. Neutral, as hypothesized:
  chat-c16 KV (16×768 tok) already fits at 0.5, so extra headroom doesn't add concurrency. (Would
  help coder/high-concurrency, but the objective is chat c16.)

### cand #4 — `20260620_moe-trtllm_tuned.sh` — **DISCARD** (serve_fail)
+ `--moe-backend flashinfer_trtllm` (baseline auto = FLASHINFER_CUTLASS).
- **serve_fail at engine init:** `ValueError: NvFp4 MoE backend 'FLASHINFER_TRTLLM' does not support
  the deployment configuration since kernel does not support current device cuda.` TRTLLM's NVFP4 MoE
  kernel is not built for sm_121 (GB10) — same exclusion class as b12x serve_fails on prior models.
  Auto's FLASHINFER_CUTLASS is already the correct/only fast NVFP4 MoE path on this device.

## Tune-loop conclusion (2026-06-20): BASELINE WINS
No candidate beat baseline (c16=220.1) by >3%: ngram −34.6%, mnbt-16384 +1.1% (noise), gpumem-0p8
+0.2% (neutral), moe-trtllm serve_fail. Bandwidth-bound MoE with auto-selected optimal kernels
(GDN Triton/FLA + FLASHINFER_CUTLASS) — same pattern as the 35B/gemma/VibeThinker campaigns. **Promote
the baseline as the winner** (serving-identical → baseline suite stands; run FULL eval at finalize).
All `*_tuned.sh` kept as the project record.
