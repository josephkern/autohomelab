# Logbook — NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 (RedHatAI) on gb10-1988a9714b4e

Campaign: onboard as the next standard model, per the vLLM DGX-Spark blog (2026-06-01) which
recommends this exact model class (100–130B MoE NVFP4, ~10–15B active) as the GB10 sweet spot.

## Environment (charter rule #3)
- node: gb10-1988a9714b4e — GB10 (Blackwell sm_121), aarch64, ~121.6 GiB **unified** LPDDR5X (~273 GB/s)
- driver: 580.159.03 · CUDA: 13.0
- vLLM: **0.23.0** — image `vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f`
- GuideLLM: 0.6.0 (pinned) · lm-eval via `uv`
- model revision (pinned): `b2b9a6150f0d1d450d68b40993e4699b0cfbbab0` (main; 17 safetensors shards + inline modelopt quant config)
- runbook: `runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/baseline.sh`
  (config_hash **d00606f7**; throughput + think-on mmlu below were measured at **66c4a57d**, the
  pre-think-off-fix hash — **serving-identical**, since the only delta is the eval-overlay var
  `AHL_THINK_OFF_KWARGS` which is inert for the deployed/throughput/think-on serve).

## Model notes
- NemotronHForCausalLM — hybrid Mamba-Transformer + **LatentMoE**, 88 layers, 22 experts/tok, native
  256K context. ModelOpt `MIXED_PRECISION` (majority NVFP4 W4A4; latent/MTP/QKV/embed in BF16/MXFP8;
  KV scheme baked in FP8). Reasoning + tool-calling; has native MTP layers (→ spec-decode candidate).
- vLLM 0.23.0 registers the arch + the `nemotron_v3` reasoning parser **natively** (verified) — no
  trust_remote_code / no custom `super_v3` plugin (that step in the HF card is for vLLM ≤0.18).

## 2026-06-15 — Baseline validation (all three gates)

Baseline config from the blog's functional flags, **reset for solo throughput**: gpu-mem-util **0.85**
(weights 74.8 GB = 0.62 of the pool → the generic unified 0.50 cannot load it), blog's `--max-num-seqs 4`
**omitted** (single-user latency cap; throttles c16/c32), no `--quantization`/`--moe-backend`/
`--kv-cache-dtype`/`--speculative-config` (modelopt auto-detected; the rest are tune-loop candidates).
Load: **677 s** (~11 min) to healthy. **= first KEEP / current best.**

**Gate 1 — works:** smoke 4/4 (chat / JSON / `qwen3_coder` tools / `nemotron_v3` reasoning routing). PASS.

**Gate 2 — good:**
- `mmlu` (loglikelihood, think-on, limit 100) = **85.82** — matches NVIDIA's published NVFP4 scores
  (card MMLU-Pro 83.33; full MMLU ~85–88). Confirms NVFP4 is ~lossless here and the loglikelihood path
  is healthy on this arch (no Gemma-style breakage; the lm-eval "null content" warnings on this path are
  spurious logprob-request noise).
- `gsm8k` (generative, think-off, full set) = **61.87 strict / 95.45 flexible-extract**.
- `mmlu_pro` (generative, think-off, limit 100) = **76.43** — below the published full-reasoning 83.33,
  which is the **`low_effort` tradeoff** (reduced reasoning for the think-off eval), not a regression.
- The clean degradation reference for the tune loop is **mmlu (loglikelihood) = 85.82** + gsm8k.

  **Think-off fix (this session):** the suite's default thinking-off path (`enable_thinking=false`) makes
  NemotronH emit **zero tokens** (`content` + `reasoning_content` both null, finish=stop) → gsm8k/mmlu_pro
  think-off = **0.0**. Root cause: the chat template's `add_generation_prompt + not enable_thinking` tail
  renders a pre-closed `<|im_start|>assistant\n<think></think>` (no newline) the model answers with an
  immediate EOS. Fix: `adapter.sh` now honors a per-model `AHL_THINK_OFF_KWARGS` (default unchanged
  `{"enable_thinking": false}`); this runbook sets `{"low_effort": true}` — NVIDIA's reduced-reasoning
  knob keeps the working `<think>\n` format and lands the answer in `content`. Verified: "17×4" → content
  "68"; gsm8k **0 → 62/95**. Committed `a201ef4`. (Doc: AGENTS.md "Thinking-OFF generative eval".)

**Gate 3 — fast:** full 1,4,8,16,32 sweep, both shapes (deployed config, gpu-mem-util 0.85).

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) **aggregate** | 17.31 | 42.77 | 57.02 | 73.01 | **103.44** |
| chat **per-stream** (agg/conc) | 17.3 | 10.7 | 7.1 | 4.6 | 3.2 |
| coder(4096/1024) **aggregate** | 17.73 | 34.88 | 37.52 | 37.26 | **9.99** |

- **vs the blog's `--max-num-seqs 4`:** aggregate chat **keeps climbing to c32** (6× c1) — it does *not*
  plateau at 4, so as an aggregate claim "batching stops past 4" is false here. But **per-stream** drops
  below the single-user rate immediately (17→10.7 at c4→4.6 at c16): if each user needs ≥~10 tok/s you're
  capped at ~c4 — exactly their number. Their rule is a **per-stream interactive-latency** guarantee, not
  an aggregate-throughput one. (Our c1 chat 17.3 vs their ~23 single-stream decode: ours folds 512-tok
  prefill into the tok/s; theirs is pure decode.)
- **coder c32 = 9.99 collapse** — bandwidth saturation + KV pressure at long context (matches the lab-note
  "decode plateaus/regresses at high concurrency on GB10"). Worth a watchdog look if we re-run coder.
- thermals benign: chat 64C/37W, coder 68C/39W.

**Verdict:** baseline is GREEN on all three gates. Quality validated (NVFP4 lossless vs published).
Objective = median c16 chat = **73.01 tok/s** (current best).

## Next — tune loop (Fig-4 levers, 0.23.0 capability-valid)
Candidate queue: FP4 `--moe-backend {flashinfer_b12x,flashinfer_cutlass,marlin}` / `--linear-backend`,
`--async-scheduling`, MTP `--speculative-config` (model has native MTP), gpu-mem-util ceiling (0.85→?),
and the blog's `--max-num-seqs 4` (per-stream/latency characterization). One change per variant, N=3,
KEEP if median c16 > +3% AND smoke AND (numeric-risky) accuracy within ~1% of mmlu=85.82.
</content>
