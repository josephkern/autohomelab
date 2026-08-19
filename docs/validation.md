# Validation — the three gates

**Reframed goal:** autohomelab produces a *completely working, tested, optimized* vLLM serve script
per model — not just the fastest config. A promoted `_final.sh` must clear **three gates**:

1. **Works (functional)** — serves, and the model's real features behave: chat coherence,
   tool-calling parses, reasoning parser emits its channel, chat template + sampling correct.
2. **Good (quality)** — accuracy within tolerance of a reference (a throughput win that degrades
   quality is a loss).
3. **Fast (throughput)** — the tok/s tuning we already do, on a number that has **passed the
   measurement-validity invariants** ([validity-contract.md](validity-contract.md)). An invalid
   tok/s figure does not fail Gate 3; it does not enter it.

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

> **Matched settings required:** recovery is valid only when variant and reference use the **same**
> eval settings (same `LIMIT` / task set). Full-vs-sampled mmlu are different question sets — that
> comparison yields a *spurious* regression. Compare LIMIT=100↔LIMIT=100 or full↔full.

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

The `run_experiment.sh` → median c16 (+ c32) loop, with one thing made explicit that was previously
assumed: **validity is a precondition of the gate, not a comment on it.** A tok/s number that fails
the invariants is not a slow Gate-3 pass or a noisy Gate-3 result — it is **not a Gate-3 result at
all**, and the gate is un-run until a valid number exists.

This is not theoretical tidying. Three defects in one session (20260817–20260819) each produced a
`status=measured` row that no human would have accepted if they had seen how it was computed: a c32
figure averaged over **2** completed requests, a `tps_c16` of **449,358** from a dead endpoint, and
a quality score computed over whatever subset of 56,168 NaN-returning requests happened to succeed.
None raised an error. The mechanism is always the same — GuideLLM's
`output_tokens_per_second.successful.mean` averages the requests that **finished**, and the
interesting failures are exactly the ones that do not finish.

Rules and thresholds are binding in [validity-contract.md](validity-contract.md) §3–5; the schema
and status vocabulary are in AGENTS.md → "Results model". What follows is how to apply the same
reasoning **by hand** to a number you are suspicious of.

### The verdicts, and what each one is actually detecting

| verdict | trips when | severity | what it is really catching |
|---|---|---|---|
| `no_data` | a run level has `successful < AHL_MIN_DATA` (**5**), or `level_c<N>.json` is missing/unparseable | **fatal** | the stage never drained — the "mean" is over a handful of lucky completions |
| `low_sample` | a run level has `successful < AHL_MIN_SUCCESSFUL` (**20**) | suspect | too few samples to separate a config difference from noise |
| `over_roofline` | a level's tok/s exceeds the physical ceiling below | **fatal** | the endpoint was dead, or fast-failing, and speed came from *not serving* |
| `nonmonotonic` | a higher concurrency level is more than **10%** below a lower one | suspect | the curve has a shape no scheduler produces — usually starvation, sometimes a wedge |
| `errored` | a level has `errored > 10%` of `successful + errored` | suspect | the config half-works; the surviving requests are a biased sample |

Fatal → the row's `status` becomes `void` (not data, must not be cited). Suspect → `suspect` (not
citable without an adjudication written into the logbook). A `crash` row stays `crash` and carries
its verdict in `validity`. `bench.sh` exits **4** on a validity failure and **3** on a crash — a
distinction worth preserving, because "the box broke" and "the numbers are not citable" call for
completely different responses (see program.md → "Invalid runs").

Two deliberate design choices worth understanding before you argue with a verdict:

- **Sample count is the primary detector; monotonicity is secondary.** The 10% inversion threshold
  is loose on purpose. On a bandwidth-bound box `c8 > c16` by a few percent is a *real, legitimate*
  result, not a defect — this node plateaus and sometimes regresses at high concurrency because
  LPDDR5X saturates. A tight monotonicity rule would fire constantly, be ignored within a week, and
  then fail to fire on the one run that mattered. Note the consequence: the starved coder run whose
  curve inverted only 2.8% (c8 70.88 > c16 68.88) is caught by `no_data`, **not** by
  `nonmonotonic`. If you catch a suspicious curve by eye, look at the counts, not the shape.
- **Unrun levels are skipped, never scored as zero.** The routine matrix is `LEVELS_SET=1,16`, so
  `tps_c4`/`tps_c8`/`tps_c32` are legitimately `na` on most rows. `na` is absence of measurement;
  `hang` is the level that wedged; `0` would be a measurement of zero throughput and never appears
  from an unrun level.

### The physical ceiling (roofline), and how to apply it by hand

Decode is memory-bandwidth-bound: with batch size B, one decode step reads the model's active
weights **once** and emits **B** tokens. So per-token weight traffic is amortized across the batch,
and aggregate throughput cannot exceed what the memory system can stream:

```
ceiling(level) = SAFETY * level * (mem_bw_GB_s / bytes_per_token_GB)
```

- `mem_bw_GB_s` — `gpu.mem_bw_gbs` from `node_profile.json` (**273** on GB10/LPDDR5X). **If the
  field is absent the check is skipped** and the row simply carries no `over_roofline` verdict.
  Never invent a bandwidth number to make the check run; a fabricated ceiling is worse than none.
- `bytes_per_token_GB` — the model's active weight bytes per decoded token, when known. When not
  known, fall back to `AHL_MIN_MODEL_GB` (**1.0 GB**), which is a deliberately generous
  under-estimate and therefore yields a sound (loose) upper bound: no real served model reads less
  than a gigabyte per token, so nothing legitimate is ever refuted by it.
- `SAFETY` — **2.0**. The bound exists to refute the *physically impossible*, not to be tight. A
  tight roofline would produce false positives on speculative decoding (MTP emits several tokens
  per verify pass, so measured throughput legitimately exceeds the naive one-token-per-step
  arithmetic) and would get ignored.

Worked example, the row that motivated the check. GB10, 273 GB/s, unknown model bytes, c16:

```
ceiling(16) = 2.0 * 16 * (273 / 1.0) = 8,736 tok/s
observed    = 449,358 tok/s                       -> over_roofline, fatal
```

Run it the other way and the absurdity is plainer: 449,358 tok/s at c16 implies each token cost
`16 * 273 / 449,358 = 0.0097` GB of weight traffic — a **9.7 MB** model. The server was dead and
returning errors instantly; "fast" was the absence of work. **This is refutable from first
principles without knowing which model was being served**, which is the whole point: you do not
need a reference number or a previous run to reject it.

The same arithmetic run forwards is the sanity check to keep in your head. Dense Q5_K_M 27B on this
box reads 21.18 GB/token, so c1 cannot exceed `273 / 21.18 = 12.9` tok/s — measured 12.03, i.e. 93%
of peak bandwidth, and there is provably no engine headroom at c1 without speculation (AGENTS.md →
llama.cpp lab notes). A number that violates its own roofline is wrong; a number that sits at 93%
of it is the hardware, not the config.

### What a Gate-3 pass requires

1. Every level in the row has `validity=ok` (or a `suspect` verdict explicitly adjudicated and
   written into `logbook.md` — never a silent one).
2. `req_counts` shows a real sample per run level: **≥20 successful** is the working rule; below 5
   the row is void. If the coder shape is starving, the fix is a larger `MAX_SECONDS` (slow dense
   models need ≥600 for `coder(4096/1024)`), not a smaller expectation.
3. The median for a keep/discard decision is taken over **valid rows only**. N=3 means three rows
   that passed the invariants, not three rows that exist.

## Keep/discard, restated
A candidate is a **keep** iff: its supporting rows are **valid** (`validity=ok`, or a `suspect`
verdict explicitly adjudicated in the logbook — never `void`) **AND** throughput improved beyond
noise **AND** smoke passes **AND** (if it touched a quality-risky knob) accuracy stayed within
tolerance. The `_final.sh` is the keep that has
also passed a **full** quality + functional validation, recorded as a validation report in the
logbook (serves ✓ / smoke ✓ / accuracy {scores} / throughput curve / pinned stack).

## Deferred
- **litellm** front door (`litellm_config.yaml` + `start-stack.sh`, ported from old-homelab) —
  added after the per-model validate→promote flow works; gives the multi-model OpenAI proxy for
  real serving.
