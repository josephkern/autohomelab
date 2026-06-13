# Research loop — best-known DGX/GB10 vLLM settings

A multi-agent research workflow that mines the *best-known* vLLM serving settings for DGX/GB10
(sm_121) from online sources, adversarially verifies them for our pinned stack, and emits a ranked
**candidate queue** for the empirical tuning loop. Script: `research/dgx-settings-research.workflow.js`.

## Principle: research proposes, the empirical loop disposes

Research finds **candidates** (what's *claimed* to help). The empirical loop
(`run_experiment.sh` → median c16 → keep/discard) is the **arbiter** — nothing is adopted until it
beats the current best on real tok/s on *this* box. Online advice is routinely wrong for the exact
version/hardware (we already caught "cu130-nightly is newer" → it was 0.19.2-dev). So every
candidate is version- and sm_121-vetted before it ever costs a benchmark run.

## Phases

1. **Sweep** (4 parallel readers, each blind to the others):
   - `nvidia` — NVIDIA primary (dev blog/forums, DGX Spark docs, NGC)
   - `vllm-gh` — vLLM DGX Spark blog + GitHub issues/PRs/discussions
   - `community` — community repos, blogs, HF model cards
   - `knobs` — per-knob deep dive (linear/moe/attention backend, kv-dtype, batched-tokens,
     num-seqs, gpu-mem-util, async-sched, cudagraph, speculative, `VLLM_*`/`FLASHINFER_*` env)
   → each returns structured candidates `{flag, value, rationale, source_url, vllm_scope, sm121_specific, confidence}`.
2. **Verify** — one adversarial verifier per unique candidate, prompted to **refute** it; default
   `uncertain` unless there's solid v0.22.0/sm_121 evidence. Keeps only `applicable`.
3. **Synthesize** — dedup, **drop already-tested** (native-fp4 KEEP, fp8-kv CRASH, async/flashinfer
   NOISE), rank by expected c16/c32 gain vs sm_121 stability risk → an experiment queue of
   `{slug, change, expected_effect, risk, provenance}`.

## Inputs it's seeded with (held constant)

sm_121 / aarch64 / CUDA 13 / 128GB unified; vLLM **v0.22.0** pinned; objective = **throughput**
(not accuracy/latency); the already-tested results above. Sampling/temperature is explicitly out of
scope (doesn't affect tok/s).

## Output → how it feeds the loop

The returned `queue` drives Phase-2: for each item, `new_variant.sh <best> <slug>` → apply
`change` → commit → `run_experiment.sh` → keep/discard. Provenance is recorded in the runbook
header and logbook.

## Cost & invocation

Multi-agent: ~4 sweep + N verify (one per unique candidate) + 1 synth ≈ **~400–800k tokens**
depending on candidate count. Run after review:

```
Workflow({ scriptPath: "research/dgx-settings-research.workflow.js" })
```

Re-runnable as new vLLM versions land (re-verify against the new pinned image + `capabilities.sh`).
