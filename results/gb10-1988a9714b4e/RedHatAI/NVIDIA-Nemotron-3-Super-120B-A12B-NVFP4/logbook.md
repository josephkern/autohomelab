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

## 2026-06-16 — Tune loop (7 candidates + stack) → winner mtp-n1

Re-measured baseline median c16 = 75.54 (this session, N=3). One change per variant, N=3 chat c1/c16.

| candidate | c16 | verdict |
|---|---|---|
| **mtp-n1** (native MTP spec-decode) | **92.77** | ✅ KEEP +22.8% (c1 17→22.8, +33%) — WINNER |
| moe-cutlass (explicit FP4 MoE) | 80.70 | ✅ +6.8%, mmlu 85.82 (quality clean) — but doesn't stack |
| async-sched | 76.93 | +1.8% noise |
| memutil-090 (0.85→0.90) | 73.54 | −2.6% (KV wasn't the c16 constraint) |
| moe-b12x | serve_fail | b12x unsupported on 0.23.0 here (as on 8B/35B) |
| moe-cutlass+mtp (stack) | 90.99 | −1.9% vs mtp — **winners don't stack** (cutlass gain vanishes under MTP) |
| maxseqs-4 (blog cap) | 39.38 | −47.9% — confirms the blog's knob is per-stream latency, not aggregate |
| trust-remote-code (df929bc) | 76.85 | inert (+1.7%) — vLLM uses built-in arch regardless; flag is config/tokenizer-only |

Lessons: MTP is the dominant lever on this bandwidth-bound model (the 35B precedent held). cutlass beats
auto solo (+6.8%) — vLLM auto does NOT pick cutlass for this LatentMoE — but the gain disappears once
MTP is active. b12x serve_fails. `--max-num-seqs 4` halves aggregate throughput (per-stream UX only).

## 2026-06-16/17 — FINALIZE + PROMOTE (winner mtp-n1)

`FULL=1 suite.sh` on mtp-n1 (cfg 479fc3da):
- **Gate 1 smoke: PASS.**
- **Gate 2 quality** (greedy, MTP-lossless): gsm8k(think-off,low_effort,full)=**59.36**, mmlu_pro(think-off,full)=**74.16**
  — consistent with baseline (61.9/76.4 @limit100). **mmlu loglikelihood (think-on) ERRORED**: MTP spec-decode
  returns **NaN prompt_logprobs** → `/v1/completions` 400s. **MTP ⊥ loglikelihood** — fundamental; the quality
  gate for any MTP config must use generative (gsm8k/mmlu_pro), not loglikelihood mmlu.
- **Gate 3 throughput** (the win): chat c1=22.4 c4=52.5 c8=69.5 **c16=93.68 c32=120.52**; the finalize coder
  sweep **hung at c1** (watchdog crash-recovered), but a **re-run was clean**: coder c1=24.5 c8=65.4 **c16=53.23
  c32=22.23** — *better* than baseline coder (37/9.99). So the hang was the documented one-off GB10
  stage-transition wedge, NOT an MTP limitation. MTP improves BOTH shapes.

**PROMOTED** → `VLLM-23-RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B_NVFP4_final.sh` (`promote.sh VLLM_TAG=23`).
Net vs baseline: **chat c16 +24% (75.5→93.7), coder c16 +43% (37→53)**, quality lossless. Caveat documented:
no loglikelihood mmlu under spec-decode (use generative gate). `*_tuned.sh` experiments kept as the record.
