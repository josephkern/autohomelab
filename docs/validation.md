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
> eval settings (same `LIMIT`, task set **and** `conc`, all three now recorded in `accuracy.tsv`),
> measured in the **same session**. Full-vs-sampled mmlu are different question sets — that
> comparison yields a *spurious* regression. Compare LIMIT=100↔LIMIT=100 or full↔full.
> Measured on the one model run both ways (`Qwen3-8B-NVFP4`, `20260613_kvfp8_tuned.sh`), `LIMIT=100`
> is **not** a random subsample: `--limit` takes the *first* L docs of each leaf, and those first
> docs are systematically easier — mmlu 73.25@100 vs 70.99@full (**−2.26 pt**), gsm8k 92.0 vs 87.64
> (**−4.36 pt**). In-loop and finalize numbers for the same config are not interchangeable.

> **And know what the bar can resolve, because `LIMIT` applies PER LEAF SUBTASK.** `mmlu` has 57
> leaves and `mmlu_pro` 14, so at `LIMIT=100`: **`gsm8k` = n 100** (SE 2.7 pt; MDE ~14 points — a
> breakage detector, nothing finer), **`mmlu_pro` = n 1,400** (SE 1.22 pt), **`mmlu` = n 5,700**
> (SE 0.509 pt, against lm-eval's own recorded median `acc_stderr` of **0.494** over the 24 kept
> `mmlu@100` bundles — the instrument has been publishing its own precision all along). `eval.sh general`
> computes gsm8k and mmlu in one run and the decision has historically read the **coarser** one off
> the row. The "~1% absolute" bar above is **not achievable unpaired at any limit on any task in
> this suite** — it needs 23,668 items per arm and `mmlu` has 14,042 in total — so treat it as an
> aspiration and use the **observed same-config repeat spread (~0.6 pt typical, ~0.9 pt seen over
> three brackets)** as the working band, cited on `mmlu@5,700`. Full derivation, and the open
> decisions it implies: `research/review/POWER-analysis.md`.

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
4. **Private held-out (mechanism built 20260820, no items authored yet):** a small eval we author
   and never publish — the only truly uncontaminated set we fully control. Runner
   `scripts/eval_private.sh`, threat model and operating rules
   [docs/private-eval.md](private-eval.md). Two things to know before using it: the committed
   `accuracy.tsv` row carries **no score**, only the set fingerprint (the score itself would be a
   public signal about private items), and the bundle records a **salted digest** of each prompt
   rather than its text. Record the model's training cutoff + each benchmark's release date in
   `accuracy.tsv` for auditability.

### Gate 2 has an acceptance predicate — `scripts/eval_validity.py` (contract A9, 20260819)

The contract originally scoped this out: every Gate-3 rule reads GuideLLM level JSON, so none of
them could see a bad *score*. Verification then found something worse than a scope gap — **Gate 2
had no acceptance predicate whatsoever.** `suite.sh` computed the gate from `eval.sh`'s exit code,
and `eval.sh` exited 0 whatever came back, so all three of these reported **PASS**:

```
lm-eval printed `mmlu: acc = NaN`           -> accuracy.tsv mmlu=nan     -> Gate 2 PASS
lm-eval scored 37 of 14,042 requested docs  -> accuracy.tsv mmlu=41.23   -> Gate 2 PASS
lm-eval produced no results json at all     -> accuracy.tsv na           -> Gate 2 PASS
```

The first two are §0 defect (c) — the spec-decode config scored by a loglikelihood task that
returned NaN for 56,168 requests while the progress bar advanced normally for 75 minutes. lm-eval
**retries and keeps going**, so it neither aborts nor exits non-zero. An exit code cannot see that.
The evidence can: every lm-eval bundle carries `n-samples` with `effective` and `original` per task.

All three now record a row and **fail** the gate. Verdict tokens are **task-tagged** the way Gate-3
tokens are level-tagged (`nonfinite@mmlu`, `short_sample@gsm8k`), `+`-joined, `ok` when clean, `na`
when unevaluable; the same void/suspect vocabulary and the same 3 > 4 > 1 > 0 exit ladder.

| verdict | trips when | severity | what it is really catching |
|---|---|---|---|
| `no_score` | no results json, unparseable, or the task carries no metric | **fatal** | lm-eval did not finish; nothing was measured |
| `nonfinite` | the headline metric is `NaN` or ±`Inf` | **fatal** | §0 defect (c) — almost always a loglikelihood task on a spec-decode serve |
| `short_sample` | `effective < 0.99 × requested` (`AHL_EVAL_MIN_SAMPLE_FRAC`) | **fatal** | the score is over a different population than the one asked for |
| `zero_score` | the headline metric is exactly `0.0` | suspect | usually a broken path, not a hard task — NemotronH emitting zero tokens under think-off, or a `\boxed` extractor mismatch |
| `no_samples` | the bundle carries no `n-samples`, so the count check could not run | suspect | fail **closed** (contract A6) |

`requested` is `min(limit, original)` summed over the task's **leaf subtasks**, which is how
`mmlu --limit 100` legitimately asks for 5,700 docs out of 14,042 and not 100. The 1% slack exists
only so one dropped doc in a 12,000-doc `FULL` run is reported rather than fatal; it still fails the
motivating case (37/14,042 = 0.26%) by two orders of magnitude. The evidence lands in the row's
`samples` column (`task=effective/requested`) so a later reader can re-derive the verdict under a
different threshold.

> **What this predicate deliberately does NOT do: compare a score to a reference or to a floor.**
> Every rule above is structural. It answers "is this a number?", never "is this number good?"; the
> relative-regression reasoning at the top of this section is how you decide whether the number is
> *good*, and it still needs a matched-settings reference. (An earlier version of this sentence
> justified the exclusion with *"at `LIMIT=100` the binomial SE is ~4.3 points"*. **That is true for
> `gsm8k` and wrong for `mmlu` by 2.8× in SE** — see the per-leaf arithmetic above. The exclusion
> stands on its own: a validity predicate and a tolerance test are different objects.)

Residual gaps, stated rather than papered over.

- lm-eval publishes **no per-request error count**, so there is no `errored`-style visibility here.
- A zero-token generation is detectable only through its 0.0 score.
- **Worst of the three: lm-eval substitutes `LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER` for a null
  completion and COUNTS THE ITEM AS ANSWERED.** So a serve returning empty content on a fifth of the
  set still records `samples=100/100`, a finite non-zero score, and `validity=ok`. Measured live on
  this box 20260820: `RedHatAI/Qwen3-8B-NVFP4` under the auto-applied thinking-OFF serve returned
  null content on **17–19%** of gsm8k items and scored **56 against a think-on 90** — Gate 2 passed
  it. A total failure would have scored 0.0 and tripped `zero_score`; a partial one scores plausibly
  and trips nothing. Until `--log_samples` is wired in (open follow-up), **look at the completions
  whenever a generative score drops sharply**, especially on a think-off serve.

`accuracy.tsv` is **16 columns** and finally carries `conc` — schema in AGENTS.md → "Results model";
operator triage in program.md → "Gate 2: when the SCORE is not a measurement".

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

Rules and thresholds are binding in [validity-contract.md](validity-contract.md) **v1.3** §3–5 —
read its amendment blocks and its closing "v1.2 status" and "v1.3" sections, which win over anything
earlier in that file; the schema and status vocabulary are in AGENTS.md → "Results model"; what the
invariants say about every number this project has already published is in
`research/review/AUDIT-measurement-validity.md`, and what those numbers can *resolve* is in
`research/review/POWER-analysis.md`.
What follows is how to apply the same reasoning **by hand** to a number you are suspicious of.

### The verdicts, and what each one is actually detecting

Verdict tokens **carry the level they refer to** — `low_sample@c1`, `no_data@c32`,
`survivorship@c16` — so gate on the level you are actually citing. Only `ok`, `nonmonotonic` and
`incomplete_run` are row-wide. This is what keeps a structurally thin c1 sentinel from condemning a
campaign's c16 objective: **300 of the 317 published rows (94.6%) carry no token tagged at c16** —
recomputed 20260820, where the corpus reads 284 `ok` / 9 suspect-floor / 23 void-floor / 1 `na`.

| verdict | trips when | severity | what it is really catching |
|---|---|---|---|
| `no_data` | `successful < AHL_MIN_DATA` (**5**), or `level_c<N>.json` missing/unparseable | **fatal** | the stage never drained — the "mean" is over a handful of lucky completions |
| `low_sample` | `successful < max(5, min(20, 4×level))` | suspect | too few completions for the level to be a sample of anything |
| `over_roofline` | a level's tok/s exceeds the physical ceiling below | **fatal** | the endpoint was dead, or fast-failing, and speed came from *not serving* |
| `no_output` | `successful > 0` but tok/s is null, non-finite or ≤ 0 | **fatal** | requests succeeded and produced **no tokens** — the floor under the roofline's ceiling |
| `survivorship` | `successful > 0` and `incomplete > successful` | suspect | a **majority** of the work started was discarded, so the published mean averages a minority of it |
| `nonmonotonic` | a run level >**10%** below the **immediately preceding** run level | suspect | a curve shape no scheduler produces |
| `errored` | `errored` is **10–50%** of `successful + errored` | suspect | the config half-works; the survivors are a biased sample |
| `errored_fatal` | `errored` is **above 50%** | **fatal** | the endpoint is refusing, not serving — the fingerprint of a dead endpoint whose tok/s happens to land under the roofline |
| `incomplete_run` | the sweep was cut short (signal, session limit, reboot). **Row-wide** | suspect | the levels that landed are real, the *run* is not a completed measurement — see below |
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

Five design choices worth understanding before you argue with a verdict:

- **Sample adequacy is a bare structural floor — and it was a token budget for exactly one day.**
  The rule has been calibrated wrong twice, so the measurements matter more than the story. v1.0's
  flat 20-request floor fired on **55%** of the published corpus (160 of 181 flagged bundles
  offended only at c1, where the count is `MAX_SECONDS / latency` — arithmetic, not operator error);
  a detector that flags the majority of good rows is a detector nobody reads. v1.1 replaced it with
  a 2048 *generated-token* budget on the premise that tokens predict reproducibility where requests
  do not. **Two verifiers refuted that independently, by different methods, and v1.2 A1 deleted the
  clause.** It fired *alone* on **3 of 693 bundles** — all three the same replicate bracket, whose
  measured CV of **0.59–0.70%** makes it *more* reproducible than most brackets on this node: three
  false positives, zero true positives. Banding CV by token budget runs backwards (0.70% under 2048
  vs 1.28% above 20k), and correlation with measured reproducibility is **r = -0.006**. Worst of
  all, a coder completion carries ~1000 tokens, so **3 requests clear a 2048 budget** and the clause
  would have **APPROVED 10 of the 15 genuinely starved levels** in the corpus. It did not merely
  fail to detect starvation, it approved it. What survives from v1.1 is only its negative half:
  request count does not predict reproducibility (median CV **0.39% at n<10**, **1.42% at
  10≤n<20**, **0.56% at 20≤n<50**) — and neither do tokens. Nothing on this corpus does, which is
  why the floor is now openly structural rather than a precision estimate.
  Two consequences worth holding onto: **`low_sample` can never fire at c1** (the floor is
  `max(5, min(20, 4×1)) = 5 = AHL_MIN_DATA`, and `no_data` claims everything below 5 first, so a c1
  stage is either `no_data` or clean — a test pins this), and **coder characterization is not
  suspect by construction**, because the floor at a given level does not care how long each
  completion was.
- **`survivorship` is a MAJORITY-discard check, and what it does *not* catch is stated, not
  implied.** GuideLLM's `output_tokens_per_second.successful.mean` silently excludes `incomplete`
  requests, and the incomplete ones are the slow ones — so the estimator is systematically
  optimistic, and grows more so with concurrency. Measured discard rates on this project's own
  record: chat c1 **0.1%**, chat c32 **10.3%**, coder c16 **32.4%**, coder c32 **46.2%**. If you
  have been reading falling high-concurrency coder numbers as saturation, read them again:
  throughput is not falling, the estimator stops keeping up.
  This rule went wrong twice before it shipped. v1.1's `incomplete ≥ successful` is arithmetically
  `successful ≤ level` (the in-flight set at stage end is ~`level`), so it **cannot fire below a 50%
  discard rate** while its own justification cited the 32.4% and 46.2% regimes above. v1.2 A2 then
  tried `incomplete > level` to subtract that in-flight set — but GuideLLM **bounds** in-flight by
  the concurrency level (88.8% of levels sit at exactly `level-1`, max ratio 1.000), so the
  condition is unsatisfiable and fired **zero times on 690 levels**. The shipped rule is
  `successful > 0 and incomplete > successful`: the published mean averages a minority of the work
  started. The 30%-threshold alternative was measured first and flags **19 of 23 coder rows** — a
  claim about the measurement METHOD, not a per-row defect, and exactly the flag fatigue this layer
  exists to avoid. **So the systemic 30–48% coder discard at c8 and above is real, is a methodology
  limitation of the coder shape at these stage times, and NO verdict flags it.** It lives in the
  AGENTS.md GuideLLM lab note and in `research/review/AUDIT-measurement-validity.md`. When you cite
  a high-concurrency coder number, read `req_counts` yourself; the fix is `MAX_SECONDS ≥ 600`.
- **`nonmonotonic` is adjacent-only, and deliberately loose.** Each run level is compared with the
  *previous run level*, never pairwise across the whole curve — this box legitimately plateaus at
  high concurrency, and a pairwise-all rule would flag gentle decay as an inversion. The 10%
  threshold is loose for the same reason. Note the consequence: the starved coder run whose curve
  inverted only 2.8% (c8 70.88 > c16 68.88) is caught by `no_data`, **not** by `nonmonotonic`. If
  you catch a suspicious curve by eye, look at the counts first — and now at `survivorship`, which
  is usually the real answer.
- **`incomplete_run` is ROW-WIDE, and that is the whole point of it.** An interrupted sweep is a
  property of the *run*, not of one concurrency level, so voiding the levels that did land would be
  the mirror-image lie. But there is a harder reason it cannot be level-tagged: `citability.py`
  deliberately **ignores `status` at level scope** (a downgrade caused by a token at some other
  level must not condemn the level you cite), so before this token existed an interrupted row read
  as *citable*, and the promotion gate printed `suspect=0` on a sweep that never finished. Only a
  row-wide token survives a level-scoped reading. It is suspect rather than fatal — the completed
  levels are data, they are just not citable until adjudicated — and any fatal verdict still
  outranks it. Recovery for the interrupts too hard for a trap (`SIGKILL`, kernel OOM, power cut):
  `scripts/reconcile_bundles.py`, which finds bundles no row references and appends a plainly
  marked reconstructed row (never `status=measured`; provenance columns `na`, never guessed).
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
2. **`req_counts` shows a real sample:** at least `max(5, min(20, 4×level))` completions on the
   level. If the coder shape is starving, the fix is a larger `MAX_SECONDS` (slow dense models need
   ≥600 for `coder(4096/1024)`), not a smaller expectation.
3. **Read the discard fraction yourself on the cited level.** `survivorship` only fires on a
   *majority* discard; the coder shape routinely discards 30–48% at c8 and above without tripping
   anything. If a third of the requests were dropped, the number is not a throughput measurement of
   the config, it is a measurement of its fastest requests — and it is biased, not noisy, so
   repeating it reproduces the same bias.
4. **Read the promotion gate's summary line, do not assume it blocked.** `promote.sh` gates the
   objective it cites: a fatal-at-the-objective row or a `crash` blocks absolutely, and so does
   having no citable objective row — but a *suspect* objective row is counted and reported
   (`suspect=N`), not blocking, while another objective row is citable. Rows outside the objective
   are reported and written into the promoted header. So a green promote is not a claim that every
   supporting row was clean.
5. **The median is over valid rows only.** `run_experiment.sh` publishes this directly on its
   `MEDIAN` line as `cite=ok|partial|insufficient|no_valid_data` alongside `valid=k/rows` —
   `ok` = all N rows valid, `partial` = 2 ≤ k < N (reported, weaker, and visibly short),
   `insufficient` = k == 1 (no median is printed at all; the lone value is reported as
   `lone_c16=` so nobody can mistake it for one), `no_valid_data` = k == 0. Read the `cite=` field
   before you read the number.
