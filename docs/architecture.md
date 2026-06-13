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
│ raw bundle in data/ + one results.tsv row.                       │
└──────────────────────────────────────────────────────────────────┘
                       │ results keyed by node fingerprint
┌─ Tune (portable) ────────────────────────────────────────────────┐
│ scripts/tune.py runs the program.md loop: baseline derived from  │
│ the probe → mutate serving config → re-sweep → keep if tok/s up.  │
└──────────────────────────────────────────────────────────────────┘
```

## Why hardware-as-data matters

The baseline serving config is **generated from `node_profile.json`** (`gen_baseline.py`):
tensor-parallel = number of GPUs, `max-model-len` and `gpu-memory-utilization` sized from VRAM,
etc. The same flow therefore yields a sane baseline on any NVIDIA box, and GB10 is just node
profile #1. Results never collide across machines because the path and every `results.tsv` row
carry the node fingerprint.

## The seam in practice

Because GuideLLM and litellm only need an OpenAI endpoint:

- Swapping vLLM for another backend is an adapter change, nothing else.
- litellm can sit in front to route/aggregate multiple endpoints without the bench layer caring.
- A run on one node can be replayed on another by re-probing and re-deriving the baseline.

## Data flow for one experiment

`probe → gen_baseline → serve (adapter up) → bench (GuideLLM) → append results.tsv + logbook →
tune decides keep/discard → next config`.
