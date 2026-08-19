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

> **Gate 2 has no validity layer.** The measurement-validity contract reads GuideLLM level JSON
> only, so it covers Gate 3 and nothing else — deliberately, and it says so in its own §0. One of
> the three defects that motivated the contract was a Gate-2 failure (loglikelihood `mmlu` on a
> spec-decode config, 56,168 requests returning `400 NaN`, a progress bar advancing normally for
> 1h15m); it was fixed by a specific branch-order fix, not by a general invariant. `accuracy.tsv`
> still records `scores` with no denominator — nothing says how many requests errored, how many
> produced empty output, or what fraction of the task set actually scored. Read a Gate-2 number
> knowing that.

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

Rules and thresholds are binding in [validity-contract.md](validity-contract.md) **v1.1** §3–5; the
schema and status vocabulary are in AGENTS.md → "Results model"; what the invariants say about every
number this project has already published is in `research/review/AUDIT-measurement-validity.md`.
What follows is how to apply the same reasoning **by hand** to a number you are suspicious of.

### The verdicts, and what each one is actually detecting

Verdict tokens **carry the level they refer to** — `low_sample@c1`, `no_data@c32`,
`survivorship@c16` — so gate on the level you are actually citing. Only `ok` and `nonmonotonic` are
row-wide. This is what keeps a structurally thin c1 sentinel from condemning a campaign's c16
objective: **94.6% of rows carry no verdict against c16.**

| verdict | trips when | severity | what it is really catching |
|---|---|---|---|
| `no_data` | `successful < AHL_MIN_DATA` (**5**), or `level_c<N>.json` missing/unparseable | **fatal** | the stage never drained — the "mean" is over a handful of lucky completions |
| `low_sample` | `successful × mean_output_tokens < AHL_MIN_TOKENS` (**2048**) **OR** `successful < max(5, min(20, 4×level))` | suspect | not enough *generated tokens* to pin the mean down |
| `over_roofline` | a level's tok/s exceeds the physical ceiling below | **fatal** | the endpoint was dead, or fast-failing, and speed came from *not serving* |
| `survivorship` | `incomplete ≥ successful` | suspect | the mean is the mean of the **faster half** — the slow requests were dropped, not counted |
| `nonmonotonic` | a run level >**10%** below the **immediately preceding** run level | suspect | a curve shape no scheduler produces |
| `errored` | `errored > 10%` of `successful + errored` | suspect | the config half-works; the survivors are a biased sample |
| `na` | the rules could not be evaluated (no bundle) | — | absence of evidence — **never** reported as `ok` |

Fatal → the row's `status` becomes `void` (not data, must not be cited). Suspect → `suspect` (not
citable without an adjudication written into the logbook). A `crash` row stays `crash`, carries its
verdict in `validity`, and is **non-valid for every consumer**. Consumers therefore filter on
**`validity`, never on `status` alone** — a crash row carrying `over_roofline` would otherwise pass
a status-only filter.

`bench.sh` exits **4** on any non-`ok` verdict (**including a lone `suspect`**) and **3** on a
crash; crash wins if both happen. Exit 4 means *"the row is written but not citable — continue"*,
not *"abort"*; the distinction between 3 and 4 is worth preserving because "the box broke" and "the
numbers are not citable" call for completely different responses (program.md → "Invalid runs").

Four design choices worth understanding before you argue with a verdict:

- **Sample adequacy is measured in tokens, not requests.** The first version of this rule used a
  flat 20-request floor and fired on **55%** of the published corpus — a detector that flags the
  majority of good rows is a detector nobody reads. Measured across 77 replicate brackets, median CV
  of reported tok/s is **0.39% at n<10** and **1.42% at 10≤n<20** against **0.56% at 20≤n<50**:
  request count does not predict reproducibility, tokens generated does. Under the token budget the
  record reads 90% ok / 4% suspect / 4% void with every motivating defect still caught. Practical
  consequence: a `coder(4096/1024)` level is **not** suspect merely for completing a handful of
  requests — at ~1024 output tokens each they clear the budget quickly, and generated tokens are the
  precision that matters. Coder characterization is citable again.
- **`survivorship` is a *bias* check, not a sample-size check.** GuideLLM's
  `output_tokens_per_second.successful.mean` silently excludes `incomplete` requests, and the
  incomplete ones are the slow ones — so the estimator is systematically optimistic, and grows more
  so with concurrency. Measured discard rates on this project's own record: chat c1 **0.1%**, chat
  c32 **10.3%**, coder c16 **32.4%**, coder c32 **46.2%**. At coder c32 nearly half the work is
  discarded before the average is taken. If you have been reading falling high-concurrency coder
  numbers as saturation, read them again: throughput is not falling, the estimator stops keeping up.
- **`nonmonotonic` is adjacent-only, and deliberately loose.** Each run level is compared with the
  *previous run level*, never pairwise across the whole curve — this box legitimately plateaus at
  high concurrency, and a pairwise-all rule would flag gentle decay as an inversion. The 10%
  threshold is loose for the same reason. Note the consequence: the starved coder run whose curve
  inverted only 2.8% (c8 70.88 > c16 68.88) is caught by `no_data`, **not** by `nonmonotonic`. If
  you catch a suspicious curve by eye, look at the counts first — and now at `survivorship`, which
  is usually the real answer.
- **Unrun levels are skipped, never scored as zero.** The routine matrix is `LEVELS_SET=1,16`, so
  `tps_c4`/`tps_c8`/`tps_c32` are legitimately `na` on most rows. `na` is absence of measurement;
  `hang` is the level that wedged; `0` would be a measurement of zero throughput and never comes
  from an unrun level. A level counts as run if the journal published a cell **or** a bundle file
  exists.

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
- `SAFETY` — **3.0**. The bound exists to refute the *physically impossible*, not to be tight, and
  the headroom is not arbitrary: MTP emits several tokens per verify pass, and **measured accepted
  length on this node reaches 2.69**, so a 2.0 multiplier would fatally void a legitimate
  spec-decode config. 3.0 still catches the 449,358 row by **34×**.
- Do **not** tighten `bytes_per_token_GB` by reading the checkpoint size. An MoE reads only its
  active experts, and the unsloth 27B's resident-but-unread vision tower makes a perfectly healthy
  run compute to 117% of peak bandwidth. A wrong tightening voids good rows, which is the more
  expensive mistake.

Worked example, the row that motivated the check. GB10, 273 GB/s, unknown model bytes, c16:

```
ceiling(16) = 3.0 * 16 * (273 / 1.0) = 13,104 tok/s
observed    = 449,358 tok/s   (34x the ceiling)   -> over_roofline@c16, fatal
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

1. **No verdict against the level you are citing.** `validity=ok`, or a `suspect` verdict that is
   explicitly adjudicated and written into `logbook.md` — never a silent one, and never a verdict
   tagged at the level whose number the decision rests on. `low_sample@c1` on a row whose objective
   is c16 is not an obstacle; `low_sample@c16` on that same row is.
2. **`req_counts` shows a real sample:** ≥2048 generated tokens on the level, and at least
   `max(5, min(20, 4×level))` completions. If the coder shape is starving, the fix is a larger
   `MAX_SECONDS` (slow dense models need ≥600 for `coder(4096/1024)`), not a smaller expectation.
3. **No `survivorship` on the cited level.** If half the requests were dropped, the number is not a
   throughput measurement of the config, it is a measurement of its fastest requests.
4. **The median is over valid rows only.** `run_experiment.sh` publishes this directly on its
   `MEDIAN` line as `cite=ok|partial|insufficient|no_valid_data` alongside `valid=k/rows` —
   `ok` = all N rows valid, `partial` = 2 ≤ k < N (reported, weaker, and visibly short),
   `insufficient` = k == 1 (no median is printed at all; the lone value is reported as
   `lone_c16=` so nobody can mistake it for one), `no_valid_data` = k == 0. Read the `cite=` field
   before you read the number.
