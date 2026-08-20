# autohomelab

A **portable LLM-serving benchmark + autotuner** for NVIDIA hardware.

Point it at any NVIDIA node. It auto-profiles the box, serves a model behind an
OpenAI-compatible endpoint, runs a standard [GuideLLM](https://github.com/vllm-project/guidellm)
throughput sweep, and (phase 2) runs a [karpathy/autoresearch](https://github.com/karpathy/autoresearch)-style
loop that tunes the serving config to **maximize tokens/sec** — with **tok/s replacing val_bpb**
as the optimization metric.

Results from every node sit side-by-side and stay comparable because each result is keyed by a
**hardware fingerprint**, so the same model on a GB10 vs an H100 vs a 4090 is one query away.

## Why

Most of a serving benchmark is hardware-agnostic — GuideLLM, litellm, the tok/s metric, and the
tuning loop all only care about an OpenAI endpoint. The only hardware-coupled parts are *which
container runs vLLM* and *what the baseline config should be*. autohomelab makes hardware a
**probed input**, not an assumption, so the whole flow is reproducible on any NVIDIA box.

## Architecture (four layers)

| Layer | What it does | Hardware-coupled? |
|---|---|---|
| **Probe** | `node_profile.json` + fingerprint (GPU, VRAM, compute cap, arch, driver, CUDA, RAM, fw) | reads it |
| **Backend** | pluggable adapter: launch server, health-check, expose OpenAI endpoint (vLLM first) | yes (pinned image per arch) |
| **Bench** | GuideLLM sweep @ 1/4/8/16/32 concurrency → tok/s curve, scored against measurement-validity invariants (per-level sample floor, majority-discard survivorship, a bandwidth roofline above and a zero-output floor below, error-rate bands) | no |
| **Tune** | program.md loop: baseline derived from probe → mutate config → re-sweep → keep if **valid** tok/s up | no |

See [docs/architecture.md](docs/architecture.md), [docs/validation.md](docs/validation.md) (the
three gates), [docs/validity-contract.md](docs/validity-contract.md) (what makes a measurement
citable) and [docs/reproducibility.md](docs/reproducibility.md).

## Repository tree

```
autohomelab/
├── README.md                     this file
├── AGENTS.md                     operating guide + living lab notes  (CLAUDE.md → symlink)
├── program.md                    autoresearch tuning agenda (tok/s replaces val_bpb)
├── pyproject.toml · uv.lock · .python-version   pinned uv tooling env (guidellm, hf)
├── .env.example                  copy → .env (gitignored): HF_TOKEN, AHL_HOST/PORT
├── .github/ISSUE_TEMPLATE/       new-node-profile.md, new-model-run.md
│
├── scripts/                      harness — bash (system) or python via `uv run`  (abridged: 35 files)
│   ├── lib/  validity.py         SINGLE source of the results.tsv header + the Gate-3 validity rules
│   │          validity.sh        thin bash shim for the bench*.sh callers (re-implements nothing)
│   ├── citability.py             the ONE classifier: "may this row be cited?" for every consumer
│   │                             (+ citability_selftest.sh — 68 reachability checks against stubs)
│   ├── eval_validity.py          Gate-2 acceptance predicate for an lm-eval score; task-tagged
│   │                             verdicts (+ eval_validity_selftest.sh — 95 checks)
│   ├── migrate_results_tsv.py    20-col -> 23-col journal migration (idempotent)
│   ├── migrate_accuracy_tsv.py   12-col -> 16-col accuracy journal; backfills conc from bundles
│   ├── probe.sh                  hardware → results/<node_fp>/node_profile.json + fingerprint
│   ├── serve.sh                  launch backend from a runbook; records load_s (time-to-healthy)
│   ├── bench.sh                  GuideLLM per-level sweep → results.tsv row (+ watchdog + sidecar);
│   │                             exit 0 clean / 3 crash / 4 not citable (incl. a lone suspect)
│   ├── suite.sh                  all three gates against one serve session → SUITE-<cfg>.md
│   ├── smoke.sh · eval*.sh       Gate 1 (functional) and Gate 2 (lm-eval / LiveBench / BFCL)
│   ├── promote.sh                winner → VLLM-<minor>-<org>_<base>_<quant>_final.sh
│   ├── run_experiment.sh         one experiment: serve once → N benches → median c16 over VALID
│   │                             rows only; publishes cite=ok|partial|insufficient|no_valid_data
│   ├── new_variant.sh            copy current best → <date>_<slug>_tuned.sh (one change)
│   ├── tune_status.py            leaderboard: median c16 per config, best ★
│   ├── gen_baseline.py           derive a baseline runbook from the node profile
│   ├── kv_calc.py                KV/memory footprint vs the unified pool (quant-aware)
│   ├── capabilities.sh           snapshot a vLLM image's flag/backend surface (don't trust memory)
│   ├── metrics_sampler.sh        GPU power/temp/util/clock timeseries sidecar
│   └── aggregate.py              concat all results.tsv → cross-node comparison
│
├── backends/                     pluggable serving adapters (OpenAI-endpoint contract)
│   ├── adapter.md                the adapter contract
│   └── vllm/  adapter.sh (Docker, image by digest) · image.lock (validated-image registry)
│
├── runbooks/<org>/<model>/       model-centric configs — pinned image + model + flags
│   └── RedHatAI/Qwen3-8B-NVFP4/  baseline.sh · <date>_<change>_tuned.sh …
│
├── results/<node_fp>/            HARDWARE-KEYED
│   └── gb10-…/  node_profile.json · node_notes.md
│       └── <org>/<model>/  results.tsv (23-col throughput journal) · accuracy.tsv (16-col Gate 2) ·
│                            logbook.md (narrative) · SUITE-<cfg>.md · data/ (raw, gitignored)
│
├── docs/   architecture.md · validation.md · validity-contract.md · reproducibility.md ·
│           contamination-resistant-evals.md · research-loop.md · charter.md · hardware/gb10-dgx-spark.md
├── tests/  run.sh — 206-test acceptance suite for the validity layer (stdlib only, no GPU,
│           no network); run it with AHL_TEST_STRICT=1, where a SKIP fails
│        mutate.sh — mutation harness: 26 mutations, 0 survivors. A rule with no mutation
│           that turns the suite red is an untested rule
├── research/review/  ULTRAPLAN-REVIEW-ISSUE.md · AUDIT-measurement-validity.md (what the
│           invariants say about every number this project has published)
├── launchers/                    symlinks → runbook .sh (convenience)
└── source/                       gitignored scratch (e.g. source/vllm clone for grepping kernels)
```

Gitignored: `.env`, `results/**/data/`, `source/*`, `.venv/`, `.ahl_serve_state`.

## Quickstart (NVIDIA node)

```bash
cp .env.example .env                                   # set HF_TOKEN etc.
scripts/probe.sh                                       # → results/<node_fp>/node_profile.json
uv run scripts/gen_baseline.py RedHatAI/Qwen3-8B-NVFP4 # → runbooks/RedHatAI/Qwen3-8B-NVFP4/baseline.sh
RB=runbooks/RedHatAI/Qwen3-8B-NVFP4/baseline.sh
scripts/serve.sh "$RB"                                 # launch vLLM (image pinned IN the runbook)
scripts/bench.sh "$RB" chat                            # GuideLLM sweep → results.tsv row + raw bundle
uv run scripts/aggregate.py                            # cross-node comparison table
scripts/serve.sh down                                  # tear the server down
```

Each runbook `.sh` is the complete reproducible unit: pinned image digest + model + flags. Tune
by copying `baseline.sh` to `<YYYYMMDD>_<change>_tuned.sh` and changing one thing.

## Reproducibility rules

1. Pin releases by version **and** image digest — no nightlies. The image is pinned **in each
   runbook**; `backends/vllm/image.lock` is the validated-image registry + default.
2. Every logbook entry records the full driver / firmware / software stack used.
3. Helper scripts are `bash` (system) or `python` via `uv`/`uvx` only.
4. `.env` and raw `data/` are never committed — which is why each `results.tsv` row carries its own
   `req_counts` / `validity` / `knobs`: the evidence for a number has to survive in the committed
   journal, not only in the gitignored bundle.
5. A measurement that fails the invariants is recorded and flagged (`status=void`/`suspect`), never
   silently dropped and never citable. Verdicts name the concurrency level they concern
   (`low_sample@c1`), and consumers filter on the `validity` column, never on `status` alone. See
   [docs/validity-contract.md](docs/validity-contract.md) (**v1.2**). The quality gate has the same
   kind of predicate: a `nan` score, a score computed over fewer samples than were requested, or a
   missing results file is not a Gate-2 result either.

## Status

- Node profile #1: **NVIDIA GB10** (Dell Pro Max GB10), aarch64, the maintainer's proving node.
