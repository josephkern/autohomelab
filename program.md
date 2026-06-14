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
- **KEEP rule:** median c16 beats the current best by **>3%** AND smoke passes AND — for a
  numeric-risky knob (kv-cache-dtype, quantization, GEMM backend) — accuracy within **~1%** of the
  reference. Else discard. (Gate definitions: AGENTS.md → "three gates".)

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

**Unattended:** drive a queue with `research/run-queue-<ver>.sh` as a *tracked background job* — it
ablates candidates vs the best, smoke-gated and crash-safe, and writes `OVERNIGHT-<ver>.md`. Safe to
leave overnight (invariants in AGENTS.md → "Unattended"); it records keep/discard and **does not
auto-promote**.

## 3. Finalize
1. On the winner, run the standard suite at FULL eval (serve → smoke → full general+resistant eval
   → both-shape full sweep → `SUITE-<cfg>.md`): `FULL=1 scripts/suite.sh <winner>`. Promote **only
   if** smoke PASS and accuracy within ~1% of reference. (If the winner is serving-identical to the
   already-suited baseline, the baseline's suite stands — note the equivalence instead of re-running.)
2. `scripts/promote.sh <winner> "<result>"` → `VLLM-<minor>-<org>_<base>_<quant>_final.sh`
   (the canonical serve config; `*_tuned.sh` artifacts kept). **Pass `VLLM_TAG=<minor>`** if the
   runbook text contains an off-version string (e.g. a migration comment) — see AGENTS.md follow-up.
3. Record the validation report + a session entry in
   `results/<node_fp>/<org>/<model>/logbook.md` (with the environment block, AGENTS rule #3).

## Done when
A validated `_final` exists for this `(node, model, vLLM version)`: all three gates pass, throughput
characterized, logbook updated. On a new vLLM release, re-run from Setup (transition = pin +
capabilities-diff + re-baseline + re-verify the queue).
