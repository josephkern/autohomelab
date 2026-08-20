# Architecture

autohomelab is four layers with one clean seam: **everything above the backend talks only to an
OpenAI-compatible endpoint.** That seam is why the benchmark and tuning layers are fully
portable, and why hardware coupling is confined to the probe and the backend.

```
┌─ Probe ─────────────────────────────────────────────────────────┐
│ scripts/probe.sh → results/<node_fp>/node_profile.json + finger- │
│ print. Records GPU(s), VRAM, compute capability, arch, driver,   │
│ CUDA, RAM, firmware. Hardware becomes DATA.                      │
└──────────────────────────────────────────────────────────────────┘
                       │ constraints
┌─ Backend (pluggable) ────────────────────────────────────────────┐
│ backends/<name>/adapter.sh launches a server from a runbook .sh  │
│ using a pinned image, exposes an OpenAI endpoint. vLLM is #1.     │
│ Contract: backends/adapter.md.                                   │
└──────────────────────────────────────────────────────────────────┘
                       │ OpenAI-compatible endpoint (the seam)
┌─ Bench (portable) ───────────────────────────────────────────────┐
│ scripts/bench.sh → GuideLLM sweep @ 1/4/8/16/32 concurrency →     │
│ raw bundle in data/ → scripts/lib/validity.py scores the bundle  │
│ → one results.tsv row carrying the numbers AND their verdict.    │
└──────────────────────────────────────────────────────────────────┘
                       │ results keyed by node fingerprint
┌─ Tune (portable) ────────────────────────────────────────────────┐
│ scripts/run_experiment.sh + tune_status.py run the program.md    │
│ loop: baseline from the probe → mutate config → re-sweep → keep   │
│ the CONFIG if the median of VALID tok/s is up.                    │
└──────────────────────────────────────────────────────────────────┘
```

## Validity sits between the bundle and the journal

The raw GuideLLM bundle is gitignored; the `results.tsv` row is committed. Everything that makes a
number *believable* — how many requests actually completed, how many errored, what knobs were in
force — used to live only on the non-committed side, so the journal recorded conclusions without
their evidence. `scripts/lib/validity.py` closes that: it reads each `level_c<N>.json`, computes the
verdicts, and writes `req_counts` / `validity` / `knobs` into the row alongside the tok/s figures.

It is the **single source of truth** for the schema and the rules — the header string and every
threshold are defined there and consumed by `bench.sh`, `bench_ds4.sh`, `bench_llamacpp.sh` and
`aggregate.py` (`scripts/lib/validity.sh` is a bash shim over it, re-implementing nothing). That
single-definition property is the point: the four writers previously hard-coded the header
independently, which is how the documented schema drifted three columns behind reality.

Consequence for the layer above: the Tune layer no longer consumes tok/s, it consumes *valid* tok/s.
`void`, `suspect` and `crash` rows are excluded from medians, and `aggregate.py` hides them by
default. `promote.sh` gates the **objective** it cites rather than every row sharing the
`config_hash`: it blocks on a fatal-at-the-objective row, on a crash, or on there being no citable
objective row at all, and it *reports* everything else (override: a written
`AHL_PROMOTE_OVERRIDE` justification of ≥12 characters, stamped into the artifact as a comment).
Consumers filter on the **`validity`** column, never on `status` alone — a crash row carrying
`over_roofline` would pass a status-only filter. Verdicts are tagged with the level they concern
(`low_sample@c1`), so a consumer gates on the level it cites.
**One classifier answers "may this row be cited?" for every consumer — `scripts/citability.py`**;
it previously existed as five hand-copied `def classify` bodies inside shell heredocs, all five
carrying the same three bugs.

**Gate 2 has the same shape** since contract A9: `scripts/eval_validity.py` is the acceptance
predicate for an lm-eval score (`no_score` / `nonfinite` / `short_sample` fatal, `zero_score` /
`no_samples` suspect, task-tagged like `nonfinite@mmlu`), and `accuracy.tsv` carries
`conc`/`samples`/`validity`/`status` in 16 columns. Before it, `suite.sh` judged the quality gate on
`eval.sh`'s exit code alone — and a `nan` score, a 37-of-14,042 run and a missing results file all
reported PASS.

**Identity is part of validity, and host-process backends had none.** A vLLM runbook *is* the
config, so `config_hash = sha256sum <runbook>` is honest. A ds4 / llama.cpp launcher leaves the
gates nothing to hash but a `.smoke-runbook.sh` stub, so every config of an engine collided on one
hash — and `promote.sh` selects supporting rows *by* `config_hash`. `scripts/lib/hostcfg.sh`
computes `hp3-<8 hex>` from the served process instead (argv, the tuning environment, and the
engine binary by content through `/proc/<pid>/exe`), and **both** `eval.sh` and the host benchers
use it, so a quality row and a throughput row for one launcher config finally join.

**An interrupted run leaves a row too.** `bench.sh` wrote its row only after the level loop, so a
hard stop mid-shape left a bundle full of real evidence that no row referenced — invisible to every
consumer, because the journal is committed and the bundle is gitignored. All three benchers now trap
and record a partial row carrying the row-wide `incomplete_run` verdict (row-wide because the
level-scoped classifier ignores `status`, so nothing narrower would have been visible to a gate);
`scripts/reconcile_bundles.py` recovers the orphans a `SIGKILL` or a power cut still produces.

Spec: [validity-contract.md](validity-contract.md) **v1.3** (its amendment blocks and closing
"v1.2 status" / "v1.3" sections win over anything earlier in that file). Acceptance:
`AHL_TEST_STRICT=1 tests/run.sh` (**279 tests**) **and** `tests/mutate.sh` (**38 mutations, 0
survivors**) — the first says the rules hold, the second says the suite would notice if they
stopped. Plus four hermetic selftests that execute the real consumers against stubs rather than
reading them as text: `scripts/citability_selftest.sh` (102),
`scripts/eval_validity_selftest.sh` (96), `scripts/hostcfg_selftest.sh` (108) and
`scripts/eval_private_selftest.sh` (261).

## Why hardware-as-data matters

The baseline serving config is **generated from `node_profile.json`** (`gen_baseline.py`):
tensor-parallel = number of GPUs, `max-model-len` and `gpu-memory-utilization` sized from VRAM,
etc. The same flow therefore yields a sane baseline on any NVIDIA box, and GB10 is just node
profile #1. Results never collide across machines because the path and every `results.tsv` row
carry the node fingerprint.

## Image pinned in the runbook

The pinned backend image (`VLLM_IMAGE`, by digest) lives **in each runbook**, not as one global
pin — image version is a per-model compatibility/tuning dimension (a newer image exposes
different kernels/backends; an NVFP4 MoE may need a backend only a specific image provides). So a
runbook is the complete reproducible unit: image + model + flags. `backends/vllm/image.lock` is a
validated-image registry + the default `gen_baseline.py` bakes into new baselines.

## The seam in practice

Because GuideLLM and litellm only need an OpenAI endpoint:

- Swapping vLLM for another backend is an adapter change, nothing else.
- litellm can sit in front to route/aggregate multiple endpoints without the bench layer caring.
- A run on one node can be replayed on another by re-probing and re-deriving the baseline.

## Data flow for one experiment

`probe → gen_baseline → serve (adapter up) → bench (GuideLLM) → validity verdict → append
results.tsv + logbook → tune keeps or drops the CONFIG on a median over VALID rows only → next
config`. The keep/drop verdict lands on the `MEDIAN` line and in the logbook, never in a row's
`status` — that column holds validity states, and its five words are
`measured` `discard` `crash` `suspect` `void`.

`bench.sh` exit codes carry the distinction downstream: **0** clean, **3** crash/hang (the box
broke), **4** any non-`ok` verdict including a lone `suspect` (the row is written, the numbers are
not citable — continue, do not abort). `run_experiment.sh` carries the same distinction up to the
operator as `cite=ok|partial|insufficient|no_valid_data` on its `MEDIAN` line.
