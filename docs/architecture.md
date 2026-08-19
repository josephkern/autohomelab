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
│ if VALID tok/s up.                                                │
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
`void` rows are excluded from medians, `promote.sh` refuses to promote on them, and `aggregate.py`
hides them by default. Spec: [validity-contract.md](validity-contract.md).

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
results.tsv + logbook → tune decides keep/discard over VALID rows only → next config`.

`bench.sh` exit codes carry the distinction downstream: **0** clean, **3** crash/hang (the box
broke), **4** validity failure (the numbers are not citable).
