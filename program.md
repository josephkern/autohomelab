# program.md — autohomelab campaign playbook

**Read `AGENTS.md` (≡ `CLAUDE.md`) first** — it holds the rules, architecture, results schema,
naming, gate definitions, and lab-notes/gotchas. THIS file is the **executable procedure**: given a
target model, run it top-to-bottom to produce a *validated, optimized* vLLM serve config (`_final`).
It says **what to do, in order**; it does not restate definitions (those are in AGENTS.md).

Mirrors [karpathy/autoresearch](https://github.com/karpathy/autoresearch): the durable artifact is
this human-maintained agenda; the agent executes it and **does not pause to ask mid-loop**.

## How to run

> "Read `program.md`, then execute for `<HFName/HFModel>`."  e.g. `RedHatAI/Qwen3-8B-NVFP4`.

Parameters (set once up front):
- `MODEL=<HFName/HFModel>` · objective = **median c16 tok/s** · `N=3` · `LEVELS_SET=1,16` (routine;
  full `1,4,8,16,32` for characterization) · `MAX_SECONDS=180`.
- **KEEP rule:** the supporting rows are **valid at the level being cited** (`validity=ok`; never
  `void` or `crash`, and `suspect` only once adjudicated in writing) AND median c16 beats the current best by **>3%** AND smoke passes AND
  — for a numeric-risky knob (kv-cache-dtype, quantization, GEMM backend) — accuracy within **~1%**
  of the reference. Else discard. (Gate definitions: AGENTS.md → "three gates"; validity vocabulary:
  AGENTS.md → "Results model"; what to do about a failure: §4 below.)

## 0. Setup
0. Harness sanity (seconds, no GPU): `AHL_TEST_STRICT=1 tests/run.sh` — the **206-test** acceptance
   suite for the measurement-validity layer, ~12 s. A SKIP means a contract rule was not checked,
   which is why strict mode fails on one. After touching a rule or an enforcement path, also run
   **`tests/mutate.sh`** (26 mutations, currently 0 survivors; a few minutes, it copies the repo per
   mutation) — a rule with no mutation that turns the suite red is an untested rule. The Gate-2
   predicate and the citability classifier have their own hermetic selftests:
   `scripts/eval_validity_selftest.sh` (95 checks) and `scripts/citability_selftest.sh` (68).
1. Node profile: `scripts/probe.sh` (skip if `results/<node_fp>/node_profile.json` exists). Confirm
   it carries `gpu.mem_bw_gbs` — without it the roofline check is silently skipped.
2. Backend image: inventory local docker images before pulling; pin the **release by digest** in
   `backends/vllm/image.lock` (never a nightly tag). `scripts/capabilities.sh` to verify version +
   record the flag/backend surface.
3. `uv run scripts/gen_baseline.py $MODEL` → `baseline.sh` + model-card stub.
4. Open the model card; **confirm the FUNCTIONAL flags** in `baseline.sh` against it (reasoning/
   tool-call parser, sampling). `uv run scripts/kv_calc.py $MODEL` to sanity-check footprint vs the
   (unified) pool.

## 1. Baseline validation — the STANDARD SUITE (all three gates, one serve)
Run the standard test suite — it serves once and runs every gate against the live endpoint, then
tears down (see AGENTS.md → "Standard test suite"):

```
scripts/suite.sh <baseline.sh>
```

This runs **Gate 1** smoke (functional 4-check), **Gate 2** eval `general` (gsm8k+mmlu reference) +
`resistant` (mmlu_pro, gpqa_diamond, tier 2), and **Gate 3** full `1,4,8,16,32` throughput sweep in
**both** `chat(512/256)` and `coder(4096/1024)` shapes. It appends results.tsv + accuracy.tsv rows
and writes `SUITE-<cfg>.md`. Record the reference scores; compare to the model card's recovery.

**Check the Gate-3 rows before recording anything:** no verdict may stand against a level you will
later cite (`validity=ok` is the clean case; a tag like `low_sample@c1` on a c16 objective is
information, `survivorship@c16` on it is a stop). The baseline is what every later candidate is
compared against, so a starved or biased baseline poisons the whole campaign — if it comes back
`no_data`, `low_sample` or `survivorship` (most often the `coder` shape at the default
`MAX_SECONDS=180`), fix it **now**, per §4.

This validated baseline is the first **keep** / current best.

## 2. Tune loop (autoresearch)
1. Build a candidate queue: known knobs + optionally the research workflow
   (`research/dgx-settings-research.workflow.js`). Each candidate must be valid for the *pinned*
   version (`capabilities.sh`); skip stale/other-version advice.
2. Per candidate (**one change**): `scripts/new_variant.sh <best> <slug>`, edit the single delta +
   header (Deltas/Hypothesis), `git commit`, then `N=3 scripts/run_experiment.sh <variant>`
   (auto smoke-gated; watchdog + per-level isolation make it crash-safe).
3. Apply the KEEP rule above; numeric-risky knobs also get `scripts/eval.sh`.
   `uv run scripts/tune_status.py --model $MODEL` shows the leaderboard / current best.
   **Read `cite=` on the `MEDIAN` line before the median itself** — `partial` means the set was
   short, `insufficient`/`no_valid_data` mean there is no median to judge. A candidate whose rows
   came back `void`/`suspect` is neither a keep nor a discard, it is **unmeasured**; resolve it per
   §4 before judging it. A candidate discarded on a starved measurement is a false negative you will
   never notice.

**Unattended:** drive a queue with `research/run-queue-<ver>.sh` as a *tracked background job* — it
ablates candidates vs the best, smoke-gated and crash-safe, and writes `OVERNIGHT-<ver>.md`. Safe to
leave overnight (invariants in AGENTS.md → "Unattended"); it records keep/discard and **does not
auto-promote**.

## 3. Finalize
1. On the winner, run the standard suite at FULL eval (serve → smoke → full general+resistant eval
   → both-shape full sweep → `SUITE-<cfg>.md`): `FULL=1 scripts/suite.sh <winner>`. Promote **only
   if** every Gate-3 row is valid, smoke PASS, and accuracy within ~1% of reference. `promote.sh`
   refuses a config supported by `void`/`suspect`/`crash` rows; the only way past it is
   `AHL_PROMOTE_OVERRIDE="<YYYYMMDD who>: why"`, which is stamped into the promoted artifact (§4). (If the winner is serving-identical to the
   already-suited baseline, the baseline's suite stands — note the equivalence instead of re-running.)
2. `scripts/promote.sh <winner> "<result>"` → `VLLM-<minor>-<org>_<base>_<quant>_final.sh`
   (the canonical serve config; `*_tuned.sh` artifacts kept). **Pass `VLLM_TAG=<minor>`** if the
   runbook text contains an off-version string (e.g. a migration comment) — see AGENTS.md follow-up.
3. Record the validation report + a session entry in
   `results/<node_fp>/<org>/<model>/logbook.md` (with the environment block, AGENTS rule #3).

## 4. Invalid runs — what to DO when a row comes back `suspect` or `void`

Any bench step in §1/§2/§3 can end in a validity failure instead of a number. The row is written
anyway, carrying `validity=<tokens>` and `status=void`/`suspect`. `bench.sh` exits **4** on any
non-`ok` verdict (**including a lone `suspect`**), **3** on a crash, **0** clean — and **exit 4
means "the row is written but not citable — continue", not "abort"**. Vocabulary and thresholds:
AGENTS.md → "Results model"; the reasoning: docs/validation.md → Gate 3.

**Verdicts name their level** (`low_sample@c1`, `survivorship@c16`), so read the tag before you
react. A verdict against a level you are not citing is information, not an obstacle: a thin c1
sentinel does not invalidate a c16 objective.

**Do not proceed on a `void` number, and do not proceed on a `suspect` number you have not
adjudicated in writing.** A procedure that only describes the happy path is how a 2-request
measurement got into a promotion decision.

### Triage by verdict

| verdict | what happened | do this |
|---|---|---|
| `no_data@cN` | the stage never drained; fewer than 5 requests finished | **re-run with a larger `MAX_SECONDS`.** Coder (4096/1024) on a slow dense model needs **≥600**. The new value lands in `knobs`, so the re-run is not silently incomparable to the old one |
| `low_sample@cN` | fewer than `max(5, min(20, 4×N))` completions finished at that level | raise `MAX_SECONDS` and re-run — more seconds, never a smaller expectation. **The token-budget clause is gone** (contract v1.2 A1): output length no longer rescues a thin level, and this verdict **cannot appear at c1** (the floor there collapses onto `AHL_MIN_DATA`=5, so c1 is either `no_data` or clean) |
| `over_roofline@cN` | the number is physically impossible: the endpoint was dead or fast-failing | **investigate the endpoint, do not re-run blind.** `scripts/serve.sh` state + `docker logs ahl-vllm` (the bundle's `vllm_crash.log` if the watchdog already tore it down) + `level_c<N>.log`. Find why requests returned instantly — usually the engine died mid-stage. Fix or discard the config, then re-serve from scratch |
| `survivorship@cN` | `incomplete > successful` — a **majority** of the work started was discarded, so the mean averages a minority of it | the number is biased upward, not noisy, so repeating it reproduces the same bias. Raise `MAX_SECONDS` until most requests finish; if they structurally cannot (coder at c32 discards ~46% even at 600 s), record the level as characterization and **do not tune against it**. **This fires only on a MAJORITY discard** — the routine 30–48% coder discard at c8+ trips nothing, so read `req_counts` yourself before citing a high-concurrency coder number |
| `no_output@cN` | requests succeeded and the level produced **no tokens** (tok/s null, non-finite or ≤ 0) | the serve is answering and generating nothing. Check the chat-template / thinking-mode path first — NemotronH emits zero tokens under `enable_thinking=false` — then the engine log. This is not a slow config, it is a broken one |
| `errored@cN` | 10–50% of requests errored; the survivors are a biased sample | read the error out of `level_c<N>.log` / engine logs. A config that half-works is a **Gate-1 problem**, not a slow Gate-3 result — re-run `scripts/smoke.sh` before spending another sweep on it |
| `errored_fatal@cN` | **above 50%** errored — the endpoint is refusing, not serving | treat it as a dead or dying endpoint, exactly like `over_roofline`: `serve.sh` state, `docker logs ahl-vllm`, the bundle's `vllm_crash.log`. This is what catches a dead endpoint whose reported tok/s happens to land *under* the roofline |
| `nonmonotonic` | a level is >10% below the one before it | check `req_counts` and `survivorship` **first** — a discarded slow half explains most apparent inversions, and starvation explains the rest. If the counts are healthy, this is a genuine finding about the config or the box: keep the row, adjudicate it in the logbook, and say why |
| `na` | the rules could not be evaluated — no bundle | the number is unverifiable, not verified. Treat as uncitable; re-run if it matters |

### Gate 2: when the SCORE is not a measurement

The same thing happens on the quality gate (docs/validity-contract.md **A9**). `eval.sh` scores its
own lm-eval bundle before writing the row and exits **4** when the score is not citable, on the
same ladder (**3** the harness was killed, **4** not citable, **1** other failure, **0** clean);
`suite.sh` and `validate.sh` latch it. The row is written either way, carrying `validity`,
`status`, `samples` (`task=effective/requested`) and `conc`.

| verdict | what happened | do this |
|---|---|---|
| `nonfinite@<task>` | the metric came back `NaN`/`Inf` | this is §0 defect (c). Almost always **a loglikelihood task on a spec-decode serve** (`NaN` prompt_logprobs -> HTTP 400 per request, and lm-eval retries and keeps going). Check the runbook for `--speculative-config`: if it is there, `mmlu` must not run at all — use generative `gsm8k`/`mmlu_pro` |
| `short_sample@<task>` | fewer samples scored than were requested (the `samples` cell has both numbers) | requests were dropped mid-run. Read the lm-eval log for repeated 400/timeout. **Do not quote the score**: it is over a different population than the one asked for. Raise `EVAL_TIMEOUT` if it was timeouts; fix the serve if it was errors |
| `no_score` | no results json, unreadable, or the task is missing from it | lm-eval did not finish. Its exit code and log say why; nothing was measured |
| `zero_score@<task>` | the metric is exactly `0.0` | **check the serve produced any tokens at all** before assuming the model is bad. NemotronH generates **zero tokens** under `enable_thinking=false` and scored gsm8k 0.0 — fixed per-model with `AHL_THINK_OFF_KWARGS`. The other common cause is an answer-extractor format mismatch (`minerva_math500` scores ~0 on `\boxed` output) |
| `no_samples@<task>` | the bundle has no `n-samples`, so completeness could not be checked | fail-closed, not a failure of the model. Re-run; if it persists the harness version changed shape |
| `na` | the predicate itself could not run | uncitable, same as Gate 3 |

**A failing Gate 2 is not a slow Gate 3.** Do not spend a throughput sweep on a config whose
quality number is not a measurement. And note what these rules deliberately do NOT do: they never
compare a score to a reference. At `LIMIT=100` the binomial SE is ~4.3 points, so the in-loop
quality check can catch gross breakage and nothing finer — see the `LIMIT=100` follow-up.

### Adjudicating a `suspect` row

`suspect` is not a soft pass. To cite one, write into `results/<node_fp>/<org>/<model>/logbook.md`:
the `run_id`, the verdict tokens **with their levels**, the `req_counts`, why the number is
nonetheless trustworthy, and what you compared it against. No entry, no citation — and never edit
the `validity` column to make a verdict go away.

At promotion the same adjudication has a machine-checked home: `AHL_PROMOTE_OVERRIDE` takes the
justification text (≥12 chars — `1`/`yes`/`force` are rejected) and `promote.sh` writes it into the
promoted `_final.sh` permanently, so every override in the repo is greppable. There is deliberately
no equivalent in `run_experiment.sh`: a tuning loop must not self-authorize.

```
AHL_PROMOTE_OVERRIDE="20260819 jk: c32 low_sample only; objective is c16, unaffected" \
  scripts/promote.sh <winner> "<result>"
```

### After a re-run

Re-runs are new rows, not replacements: the invalid row **stays in `results.tsv`** as evidence.
Reference the superseded `run_id` in the logbook entry so the pair is traceable. If the fix changed
a knob (`MAX_SECONDS`, `LEVELS_SET`, shape), the old and new rows are **not** a matched pair — the
`knobs` column will show the difference, and any comparison across it has to be re-based, in-session,
against a reference measured with the new knobs.

### Mid-campaign consequences

- **In the tune loop (§2):** `void`, `crash` and unadjudicated `suspect` rows do not count toward
  N=3. `run_experiment.sh` publishes the arithmetic on its `MEDIAN` line —
  `cite=ok|partial|insufficient|no_valid_data` plus `valid=k/rows void=… suspect=… crash=…`:
  `partial` (2 ≤ k < N) still reports a median and exits 0, `insufficient` (k == 1) reports **no
  median at all** (the lone value comes back as `lone_c16=`) and exits 4, `no_valid_data` exits 4.
  **Read `cite=` before you read the number.** Do not top a short set back up to N — "don't change N
  mid-run" — because re-benching until three rows survive biases the set toward whatever the box was
  doing when it felt healthy.
- **At finalize (§3):** if any Gate-3 row supporting the winner is `void`, `crash`, or an
  unadjudicated `suspect`, the winner is **not promotable**; `promote.sh` refuses it. Re-measure, or
  adjudicate in writing via `AHL_PROMOTE_OVERRIDE`.
- **A `crash` still outranks validity, and is non-valid for every consumer.** A row that wedged
  stays `status=crash` (its verdict, including the level, is recorded in `validity`) and is handled
  as a wedge: preserve `vllm_crash.log`, and if it matches the GB10 signature run the forensics in
  `research/upstream/vllm-43885-gb10-wedge.md` **before** the container is torn down.
- **Filter on `validity`, never on `status` alone** when querying the journal — `aggregate.py`
  hides void/suspect by default and takes `--include-void` / `--include-suspect` / `--validity
  <token>` when you want to look at them deliberately.

## Done when
A validated `_final` exists for this `(node, model, vLLM version)`: all three gates pass on **valid**
rows (no `void`, no unadjudicated `suspect` in the supporting set), throughput characterized, logbook
updated. On a new vLLM release, re-run from Setup (transition = pin +
capabilities-diff + re-baseline + re-verify the queue).
