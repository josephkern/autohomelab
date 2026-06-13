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

## Gate 2 — quality (`scripts/eval.sh`, lm-evaluation-harness)
- **Eval set by model type:** general/reasoning → `gsm8k + mmlu`; coder → `humaneval + mbpp`
  (humaneval/mbpp execute generated code → trust-only, `HF_ALLOW_CODE_EVAL`). gsm8k on reasoning
  models needs a higher `max_gen_toks` (CoT overruns 256).
- **Reference = the model card's published recovery/eval scores** (RedHatAI NVFP4 cards report
  recovery vs the base model); fallback = a one-time eval of the base/unquantized model.
- **Bar:** within **~1% absolute (≈≥99% recovery)** of reference, no single-task cliff. Tunable.
- **Cost discipline (outer loop):** tune on tok/s; quality-gate only the throughput **winner** and
  any **quality-risky** flag (kv-cache-dtype, quantization, GEMM backend) — most perf flags
  (batched-tokens, scheduling) can't change outputs, so they need no eval. Use `LIMIT` (sampled)
  for in-loop checks; **full run** for the final validation report.

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
