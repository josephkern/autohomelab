# Logbook — WeiboAI/VibeThinker-3B on gb10-1988a9714b4e

Campaign: onboard a tiny long-CoT competition-math model (paper 2606.16140). "A bit different" — a 3B
that claims frontier AIME. Quality gate = **competition-math** (user chose Option B), not gsm8k/mmlu.

## Environment (charter rule #3)
- node: gb10-1988a9714b4e — GB10 (Blackwell sm_121), aarch64, ~121.6 GiB unified LPDDR5X; driver 580.159.03, CUDA 13.0
- vLLM **0.23.0** — `vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f`
- lm-eval 0.4.12 (+ `[math]` extra) via uv; model rev (pinned, cached): `0c7115fdd0957b3da0f2a0829ab1763969d30300`
- runbook: `runbooks/WeiboAI/VibeThinker-3B/baseline.sh` (config_hash 727fd7ca)

## Model
Qwen2ForCausalLM (Qwen2.5-3B base), DENSE BF16, 5.8 GB, 36 layers, native ctx 131072 (64K trained),
sliding_window 32768. Long-CoT reasoner: emits DeepSeek-R1 `<think>…</think>` + `\boxed{}` answer (despite
the card saying no `<think>`). Rec sampling temp1.0/top_p0.95/top_k-1. Loads in 136 s.

## 2026-06-17 — Baseline validation

Baseline: stock Qwen2 + sampling override, **no reasoning/tool parser** (kept parser-less so the boxed answer
always survives in `content`), `--max-model-len 40960` (fit the long-CoT eval; short throughput shapes unaffected).

- **Gate 1 — works:** smoke **2/2 PASS** (chat + JSON; tool/reasoning gracefully skip — model has neither configured).
- **Gate 2 — good (competition-math, the chosen gate):** `eval.sh math` (aime24,aime25) via the CHAT endpoint
  (THINK=off → apply_chat_template), **temp 1.0** (do_sample=True; the model's RL regime — greedy risks loops),
  GEN_TOKS 32768, EVAL_TIMEOUT 1800, full 30 Q each.
  → **aime24 = 90.0%, aime25 = 86.67%** (Pass@1, single-sample). Paper AIME26 = 94.3 (averaged Pass@1, diff
  year) → our single-sample is in-band. **A cached 3B reproduces frontier competition-math on the GB10 stack.**
  (A few of the longest chains hit the 1800s tail timeout → true scores possibly a hair higher.)
- **Gate 3 — fast:** PENDING (throughput bench chat+coder).

### Pipeline hardening (long-CoT eval — reusable for any such model)
Onboarding this model surfaced 4 gaps, all fixed + committed:
1. `lm-eval[math]` extra (sympy/math_verify/antlr4) — symbolic answer verification (else ModuleNotFound).
2. `EVAL_TIMEOUT` model_arg (default 1800s) — 32K-token gens take many minutes, blowing lm-eval's 300s default → no results.
3. Eval the `math` suite at **temp 1.0** (GEN_KWARGS do_sample=True), not greedy — RL-reasoning models loop under greedy.
4. **MATH-500 extraction mismatch:** minerva_math500 ("Final Answer: … I hope it is correct" regex) and
   hendrycks_math500 (`$…$`) do NOT extract `\boxed{}` → score ~0 (format, not failure). The `aime` tasks
   PREFER `\boxed{}` (last_boxed_only_string) → correct. Hence the `math` suite = aime24,aime25.

### Gate 3 — fast (throughput, full sweep)
| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 29.8 | 132.9 | 258.3 | **485.1** | **852.7** |
| coder(4096/1024) | 28.6 | 109.0 | 193.9 | 304.4 | 400.3 |
**Compute-bound** (not bandwidth-bound like the NVFP4 MoEs): chat scales to c32 (28× c1), no collapse.

## 2026-06-17 — Tune loop + FINALIZE → baseline promoted

Lean queue (throughput-only — BF16 weights unchanged, so no quality eval; the aime gate stands).
Baseline re-measured median **c16 = 509.8** (N=3).
| candidate | c16 | verdict |
|---|---|---|
| async-sched | 510.4 | discard (+0.1%, noise) |
| batched-32k | 507.6 | discard (−0.4%, noise) |

Neither lever bites on an already-GPU-bound 3B → **baseline stands** (cf. 35B/gemma: baseline promoted by
default). **PROMOTED** → `VLLM-23-WeiboAI_VibeThinker-3B_final.sh` (`promote.sh VLLM_TAG=23`). All three
gates validated on the baseline config (727fd7ca). `*_tuned.sh` experiments kept.

**Campaign result:** a cached 3B BF16 Qwen2.5 serves frontier competition-math (aime24 90.0 / aime25 86.67,
temp-1.0 Pass@1) at strong throughput (chat c16 485 / c32 853) on a single GB10 — no quant, stock vLLM 0.23.0.
Caveat: aime24/25 predate the model → possible training contamination; the clean signal is the paper's AIME26.
</content>
