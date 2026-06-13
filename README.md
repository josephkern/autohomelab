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
backends/             pluggable serving adapters (vllm/ first); adapter.md = the contract; image.lock = registry
runbooks/<org>/<model>/   model-centric recipes — the .sh (pinned image + model + flags) each row references
results/<node_fp>/<org>/<model>/  hardware-keyed: results.tsv (data) + logbook.md (narrative) + data/ (raw, gitignored)
results/<node_fp>/node_profile.json, node_notes.md   probed facts + per-box hardware narrative
launchers/            symlinks to runbook .sh files
docs/                 architecture, reproducibility, hardware/<platform>.md notes
```

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
4. `.env` and raw `data/` are never committed.

## Status

- Node profile #1: **NVIDIA GB10** (Dell Pro Max GB10), aarch64, the maintainer's proving node.
