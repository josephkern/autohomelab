# program.md — the autohomelab research agenda

This is the durable, human-maintained agenda for the autonomous tuning agent, mirrored on
[karpathy/autoresearch](https://github.com/karpathy/autoresearch). The agent reads this file and
the current runbook serving config, proposes a change, runs the benchmark, and keeps or discards
based on the metric. The substitution from autoresearch: **maximize tok/s** instead of minimize
`val_bpb`.

## Setup

- The target is a single `(node, model)` pair. The node is identified by its fingerprint from
  `scripts/probe.sh` (`results/<node_fp>/node_profile.json`); the model by its HF id + revision.
- Your **first run is always the baseline**: run `runbooks/<org>/<model>/baseline.sh` as-is. The
  baseline is generated from the node profile (`scripts/gen_baseline.py`) — do not hand-edit it.
- Everything is locked **except the serving config** for the current `(node, model)`: a runbook
  `.sh` file. You may not touch the probe, the benchmark harness, the model weights, or the
  pinned backend image.

## Experimentation

- **Goal: get the highest tok/s.** The headline number is throughput at the concurrency levels
  1, 4, 8, 16, 32. Optimize for the aggregate, but never regress c1 latency-bound throughput to
  zero — a config that fails to serve any concurrency level is a `crash`.
- Fair game to change in the serving config: `max-num-seqs`, `max-num-batched-tokens`,
  `gpu-memory-utilization`, KV-cache dtype, chunked prefill, prefix caching, quantization,
  `max-model-len`, scheduler/eager flags, CUDA graph capture sizes.
- **All else being equal, simpler is better.** A change must earn its complexity with a real
  tok/s gain.
- The model, the request distribution, and the GuideLLM sweep are fixed — they are the
  controlled variable.

## Output format

Each run produces a raw GuideLLM bundle under `results/<node_fp>/<model>/data/<run_id>/` and a
single peak-memory reading. Extract per-concurrency output tok/s and peak GB.

## Logging results

Append one row to `results/<node_fp>/<model>/results.tsv`:

```
run_id  commit  model  backend  config_hash  script  tps_c1  tps_c4  tps_c8  tps_c16  tps_c32  peak_gb  status  data
```

- `status` = `keep` if it beat the current best aggregate tok/s, else `discard`; `crash` if it
  failed to serve.
- Then write a short narrative line in `logbook.md`: what you changed, the effect, and the call.

## The experiment loop

1. Read `program.md` and the current best runbook `.sh`.
2. Decide one change. Write it to a new `<YYYYMMDD>_<change>_tuned.sh` (copy of current best).
3. `git add` + commit the config (so the row's `commit` is meaningful).
4. `scripts/serve.sh <that .sh>` → health check → `scripts/bench.sh <org>/<model>`.
5. Append the `results.tsv` row + `logbook.md` narrative.
6. If it improved, this config becomes the new best (advance). If not, discard it. Either way,
   continue — **do not pause to ask the human whether to continue.**

## Reproducibility (non-negotiable)

- Backend image pinned by `sha256:` digest (`backends/vllm/image.lock`); tooling pinned via
  `uv.lock`.
- The `logbook.md` environment block records driver, firmware, CUDA, image digest, vLLM version,
  GuideLLM version, and model revision for every session.
