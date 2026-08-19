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
- **KEEP rule:** the supporting rows are **valid** (`validity=ok`; never `void`, and `suspect` only
  once adjudicated in writing) AND median c16 beats the current best by **>3%** AND smoke passes AND
  — for a numeric-risky knob (kv-cache-dtype, quantization, GEMM backend) — accuracy within **~1%**
  of the reference. Else discard. (Gate definitions: AGENTS.md → "three gates"; validity vocabulary:
  AGENTS.md → "Results model"; what to do about a failure: §4 below.)

## 0. Setup
1. Node profile: `scripts/probe.sh` (skip if `results/<node_fp>/node_profile.json` exists).
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

**Check the Gate-3 rows before recording anything:** `validity` must be `ok` on every row you are
about to treat as the reference curve. The baseline is the number every later candidate is compared
against, so a starved or void baseline poisons the whole campaign — if it comes back `no_data` or
`low_sample` (most often the `coder` shape at the default `MAX_SECONDS=180`), fix it **now**, per §4.

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
   A candidate whose rows came back `void`/`suspect` is neither a keep nor a discard — it is
   **unmeasured**. Resolve it per §4 before judging it; a candidate discarded on a starved
   measurement is a false negative you will never notice.

**Unattended:** drive a queue with `research/run-queue-<ver>.sh` as a *tracked background job* — it
ablates candidates vs the best, smoke-gated and crash-safe, and writes `OVERNIGHT-<ver>.md`. Safe to
leave overnight (invariants in AGENTS.md → "Unattended"); it records keep/discard and **does not
auto-promote**.

## 3. Finalize
1. On the winner, run the standard suite at FULL eval (serve → smoke → full general+resistant eval
   → both-shape full sweep → `SUITE-<cfg>.md`): `FULL=1 scripts/suite.sh <winner>`. Promote **only
   if** every Gate-3 row is valid, smoke PASS, and accuracy within ~1% of reference (`promote.sh`
   refuses a config supported by `void`/`suspect` rows). (If the winner is serving-identical to the
   already-suited baseline, the baseline's suite stands — note the equivalence instead of re-running.)
2. `scripts/promote.sh <winner> "<result>"` → `VLLM-<minor>-<org>_<base>_<quant>_final.sh`
   (the canonical serve config; `*_tuned.sh` artifacts kept). **Pass `VLLM_TAG=<minor>`** if the
   runbook text contains an off-version string (e.g. a migration comment) — see AGENTS.md follow-up.
3. Record the validation report + a session entry in
   `results/<node_fp>/<org>/<model>/logbook.md` (with the environment block, AGENTS rule #3).

## 4. Invalid runs — what to DO when a row comes back `suspect` or `void`

Any bench step in §1/§2/§3 can now end in a validity failure instead of a number. `bench.sh` exits
**4** (validity) as distinct from **3** (crash/hang) and **0** (clean), and the row is written
anyway with `validity=<tokens>` and `status=void`/`suspect`. Vocabulary and thresholds:
AGENTS.md → "Results model"; the reasoning: docs/validation.md → Gate 3.

**Do not proceed on a `void` number, and do not proceed on a `suspect` number you have not
adjudicated in writing.** A procedure that only describes the happy path is how a 2-request
measurement got into a promotion decision.

### Triage by verdict

| verdict | what happened | do this |
|---|---|---|
| `no_data` | the stage never drained; fewer than 5 requests finished | **re-run with a larger `MAX_SECONDS`.** Coder (4096/1024) on a slow dense model needs **≥600**; scale until `req_counts` shows ≥20 per level. Note the new `MAX_SECONDS` — it lands in `knobs`, so the re-run is not silently incomparable to the old one |
| `low_sample` | ran, but under 20 successful on some level | same fix (raise `MAX_SECONDS`), then re-run. If ≥20 is structurally unreachable for that level — `coder` c1 tops out near 12 requests per 600 s stage — say so explicitly in the logbook and treat the level as characterization, not as a tuning objective |
| `over_roofline` | the number is physically impossible: the endpoint was dead or fast-failing | **investigate the endpoint, do not re-run blind.** `scripts/serve.sh` state + `docker logs ahl-vllm` (the bundle's `vllm_crash.log` if the watchdog already tore it down) + `level_c<N>.log`. Find why requests returned instantly — usually the engine died mid-stage. Fix or discard the config, then re-serve from scratch |
| `errored` | >10% of requests errored; the survivors are a biased sample | read the error out of `level_c<N>.log` / engine logs. A config that half-works is a **Gate-1 problem**, not a slow Gate-3 result — re-run `scripts/smoke.sh` before spending another sweep on it |
| `nonmonotonic` | the curve inverts by >10% | check `req_counts` **first** — starvation explains most inversions and is the real verdict. If the counts are healthy, this is a genuine finding about the config or the box: keep the row, adjudicate it in the logbook, and say why |

### Adjudicating a `suspect` row

`suspect` is not a soft pass. To cite one, write into `results/<node_fp>/<org>/<model>/logbook.md`:
the `run_id`, the verdict tokens, the `req_counts`, why the number is nonetheless trustworthy, and
what you compared it against. No entry, no citation — and never edit the `validity` column to make
a verdict go away.

### After a re-run

Re-runs are new rows, not replacements: the invalid row **stays in `results.tsv`** as evidence.
Reference the superseded `run_id` in the logbook entry so the pair is traceable. If the fix changed
a knob (`MAX_SECONDS`, `LEVELS_SET`, shape), the old and new rows are **not** a matched pair — the
`knobs` column will show the difference, and any comparison across it has to be re-based, in-session,
against a reference measured with the new knobs.

### Mid-campaign consequences

- **In the tune loop (§2):** a `void` row does not count toward N=3. Re-run until you have three
  valid rows, or drop the candidate — never median over what is there.
- **At finalize (§3):** if any Gate-3 row supporting the winner is `void` or an unadjudicated
  `suspect`, the winner is **not promotable**; `promote.sh` refuses it. Re-measure, then promote.
- **A `crash` still outranks validity.** A row that wedged stays `status=crash` (its verdict is
  recorded in `validity`) and is handled as a wedge: preserve `vllm_crash.log`, and if it matches
  the GB10 signature run the forensics in `research/upstream/vllm-43885-gb10-wedge.md` **before**
  the container is torn down.

## Done when
A validated `_final` exists for this `(node, model, vLLM version)`: all three gates pass on **valid**
rows (no `void`, no unadjudicated `suspect` in the supporting set), throughput characterized, logbook
updated. On a new vLLM release, re-run from Setup (transition = pin +
capabilities-diff + re-baseline + re-verify the queue).
