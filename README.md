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
| **Bench** | GuideLLM sweep @ 1/4/8/16/32 concurrency → tok/s curve | no |
| **Tune** | program.md loop: baseline derived from probe → mutate config → re-sweep → keep if tok/s up | no |

See [docs/architecture.md](docs/architecture.md) and [docs/reproducibility.md](docs/reproducibility.md).

## Layout

```
program.md            autoresearch-style research agenda (tok/s replaces val_bpb)
scripts/              probe.sh, serve.sh, bench.sh, gen_baseline.py, aggregate.py, tune.py
backends/             pluggable serving adapters (vllm/ first); adapter.md = the contract
runbooks/<org>/<model>/   model-centric config recipes — the .sh each result row references
results/<node_fp>/<model>/  hardware-keyed results: results.tsv (data) + logbook.md (narrative) + data/ (raw, gitignored)
launchers/            symlinks to runbook .sh files
docs/                 architecture & reproducibility notes
```

## Quickstart (NVIDIA node)

```bash
cp .env.example .env            # set HF_TOKEN etc.
scripts/probe.sh                # → results/<node_fp>/node_profile.json
scripts/gen_baseline.py Qwen/Qwen3-8B   # → runbooks/Qwen/Qwen3-8B/baseline.sh
scripts/serve.sh runbooks/Qwen/Qwen3-8B/baseline.sh   # launch vLLM (pinned image)
scripts/bench.sh Qwen/Qwen3-8B  # GuideLLM sweep → results.tsv row + raw bundle
scripts/aggregate.py            # cross-node comparison table
```

## Reproducibility rules

1. Pin releases by version **and** image digest — no nightlies. (`backends/vllm/image.lock`)
2. Every logbook entry records the full driver / firmware / software stack used.
3. Helper scripts are `bash` (system) or `python` via `uv`/`uvx` only.
4. `.env` and raw `data/` are never committed.

## Status

- Node profile #1: **NVIDIA GB10** (Dell Pro Max GB10), aarch64, the maintainer's proving node.
