# Validation — the three gates

**Reframed goal:** autohomelab produces a *completely working, tested, optimized* vLLM serve script
per model — not just the fastest config. A promoted `_final.sh` must clear **three gates**:

1. **Works (functional)** — serves, and the model's real features behave: chat coherence,
   tool-calling parses, reasoning parser emits its channel, chat template + sampling correct.
2. **Good (quality)** — accuracy within tolerance of a reference (a throughput win that degrades
   quality is a loss).
3. **Fast (throughput)** — the tok/s tuning we already do.

Everything still talks to the OpenAI endpoint, so the new gates are just more endpoint clients
(portable, like GuideLLM).

## Gate 1 — functional smoke (`scripts/smoke.sh`)
Beyond `/v1/models`: send representative requests and assert features work — a coherent chat
completion, a tool-call that round-trips and parses (when `--tool-call-parser` is set), the
reasoning channel (when `--reasoning-parser` is set), and structured/JSON output. Fast (seconds).
A config that fails smoke is rejected regardless of tok/s.

## Gate 2 — quality (`scripts/eval.sh` / `scripts/eval_live.sh`)

**Gate 2 is a RELATIVE regression check, not a leaderboard score.** It asks one question: *did this
serving/quant config degrade the model vs. the SAME model's reference?* We compare to a reference
(model-card recovery numbers, or a one-time base/unquantized eval) and report **recovery %**
(`scripts/recovery.py`), never absolute scores as a claim. **Bar:** within **~1% absolute / ≥99%
recovery**, no single-task cliff. Tunable.

### Why relative framing matters: benchmark contamination
Static benchmarks (MMLU, GSM8K, HumanEval, MBPP) are widely scraped and almost certainly in most
pretraining corpora; some models are trained *directly* on eval sets (Qwen-Coder-Next documents
training against SWE-bench; contamination is acknowledged even for frontier models). So **absolute**
scores are unreliable. But for *our* purpose — guarding against quantization/config regressions —
contamination **largely cancels in the delta**: if reference and variant are equally contaminated,
the recovery % is still a valid "did we hurt quality" signal. Residual risk: quant could
differentially affect memorized vs reasoned items — mitigated by the resistant tier below.

### Eval tiers (use the cheapest sufficient signal; trust the resistant ones)
1. **Comparative (cheap, relative-only):** by model type — general/reasoning `gsm8k + mmlu`; coder
   `humaneval + mbpp` (code is executed → trust-only, `HF_ALLOW_CODE_EVAL`; gsm8k on reasoning
   models needs higher `max_gen_toks`). Treat ONLY as a recovery delta, never absolute.
2. **Harder / cleaner (in-harness):** **GPQA** (google-proof) + **MMLU-Pro** via lm-eval — much
   less memorized than MMLU. Add as the `resistant` suite in `eval.sh`.
3. **Time-gated GOLD (contamination-free by construction):** **LiveBench** (general) and
   **LiveCodeBench** (code) via `scripts/eval_live.sh`, **date-gated to AFTER the model's training
   cutoff** (`--livebench-release-option <date>`) so the questions can't have been trained on. This
   is the trustworthy *absolute-ish* signal; use it for the promotion decision on models we care about.
4. **Private held-out (future):** a small eval we author and never publish — the only truly
   uncontaminated set we fully control. Record the model's training cutoff + each benchmark's
   release date in `accuracy.tsv` for auditability.

- **Cost discipline (outer loop):** tune on tok/s; quality-gate only the throughput **winner** and
  any **quality-risky** flag (kv-cache-dtype, quantization, GEMM backend) — most perf flags can't
  change outputs, so they need no eval. `LIMIT`-sampled in-loop; full + a resistant/time-gated run
  for the final validation report.

## Gate 3 — throughput
The existing `run_experiment.sh` → median c16 (+ c32) loop, unchanged.

## Keep/discard, restated
A candidate is a **keep** iff: throughput improved beyond noise **AND** smoke passes **AND** (if it
touched a quality-risky knob) accuracy stayed within tolerance. The `_final.sh` is the keep that has
also passed a **full** quality + functional validation, recorded as a validation report in the
logbook (serves ✓ / smoke ✓ / accuracy {scores} / throughput curve / pinned stack).

## Deferred
- **litellm** front door (`litellm_config.yaml` + `start-stack.sh`, ported from old-homelab) —
  added after the per-model validate→promote flow works; gives the multi-model OpenAI proxy for
  real serving.
