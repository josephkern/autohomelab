# AGENTS.md — operating guide for autohomelab

This file is the contract for any agent (or human) working in this repo. `CLAUDE.md` is a
symlink to it. For the autonomous tuning agenda, see [program.md](program.md).

## What this project is

A portable LLM-serving benchmark + autotuner for NVIDIA hardware. The metric is **tokens/sec**
measured by GuideLLM at 1/4/8/16/32 concurrent sessions. Hardware is a **probed input**, not an
assumption; every result is keyed by a hardware fingerprint.

## Hard rules (from the project charter)

1. **Reproducibility is paramount.** Pin releases by version *and* digest. No nightlies. A
   release tag is an acceptable starting point only if the underlying release is pinned directly
   (e.g. an image `sha256:` digest in `backends/vllm/image.lock`).
2. **Benchmarking = tok/s @ 1, 4, 8, 16, 32 concurrency, via GuideLLM.** Nothing else for now.
3. **Every logbook entry records the full stack**: GPU driver, firmware, CUDA, container image
   digest, vLLM version, GuideLLM version, model revision (HF commit), and the runbook script.
4. **Helper scripts are `bash`** (for system/services) **or `python` via `uv`/`uvx`** in a venv.
   No global pip installs, no other languages.
5. **`.env` is never committed.** Raw GuideLLM output (`results/**/data/`) is never committed.
6. This is a **repeatable process** — prefer generating config from the probe over hardcoding.

## The four layers

- **Probe** (`scripts/probe.sh`) → `results/<node_fp>/node_profile.json` + a stable fingerprint.
- **Backend** (`backends/<name>/adapter.sh`) → launches a server, health-checks it, exposes an
  OpenAI-compatible endpoint. Contract in [backends/adapter.md](backends/adapter.md). vLLM first.
- **Bench** (`scripts/bench.sh`) → GuideLLM sweep against the endpoint → raw bundle + one
  `results.tsv` row.
- **Tune** (`scripts/tune.py`) → the program.md loop; mutates the runbook `.sh` serving config to
  maximize tok/s, keeps/discards by result.

## Results model (autoresearch-adapted)

Per **(node, model)** under `results/<node_fp>/<model>/`:

- **`results.tsv`** — the *data journal*, one row per experiment. Committed. Each row points at
  the `script` that produced it and the `data/` bundle of raw output.
- **`logbook.md`** — the *narrative*. Committed. Prose about what was tried/kept/discarded and
  why, plus the environment block (rule #3).
- **`data/`** — raw GuideLLM bundles, one dir per `run_id`. Gitignored.

`results.tsv` columns:

```
run_id  commit  model  backend  config_hash  script  tps_c1  tps_c4  tps_c8  tps_c16  tps_c32  peak_gb  status  data
```

`status` ∈ `keep` / `discard` / `crash`. `backend` encodes `vllm@<ver>(img:sha256:<short>)`.

## Conventions

- Runbooks are **model-centric**: `runbooks/<HFOrg>/<Model>/`. `baseline.sh` is generated from
  the probe; tuned variants are named `<YYYYMMDD>_<change>_tuned.sh`.
- Dates are absolute (`YYYYMMDD`).
- Commit config changes *before* running, so a `results.tsv` row's `commit` is meaningful.
- Don't pause to ask during an autonomous tuning run — follow program.md.
