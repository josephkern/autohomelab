# Reproducibility

Reproducibility is the top project rule. A benchmark number is only meaningful if the entire
stack that produced it is pinned and recorded.

## What gets pinned

| Thing | How | Where |
|---|---|---|
| Backend container | full image ref **+ `sha256:` digest** (no `latest`) | runbook `.sh` (`VLLM_IMAGE`); registry/default in `backends/<name>/image.lock` |
| Python tooling (GuideLLM, helpers) | `uv.lock` (exact versions) | repo root |
| Python version | `.python-version` | repo root |
| Model weights | HF repo id **+ revision commit hash** | runbook `.sh` + logbook |
| Serving config | the runbook `.sh`, committed before the run | `runbooks/<org>/<model>/` |

## What gets recorded per run

Every `logbook.md` session opens with an **environment block** (project rule #3):

```
- date:            YYYYMMDD HH:MM TZ
- node fingerprint: <node_fp>
- GPU:             <name> x<count>, <vram> GB, compute <cc>
- arch:            <aarch64|x86_64>
- driver:          <nvidia driver version>
- CUDA:            <cuda version>
- firmware:        <vbios / board fw if available>
- backend image:   <ref>@sha256:<digest>
- vLLM:            <version>
- GuideLLM:        <version>
- model:           <hf id>@<revision>
- runbook:         <path to .sh>
```

Most of this is emitted automatically by `probe.sh` (hardware/driver) and the backend
`adapter.sh info` (image/version); the rest is filled by `bench.sh` when it writes the row.

## Replaying a run on another node

1. `scripts/probe.sh` on the new node → new `node_profile.json` + fingerprint.
2. `scripts/gen_baseline.py <model>` → a baseline sized for the new hardware.
3. Pull the **same pinned image digest** from `image.lock` (architecture-appropriate variant).
4. Run the same `bench.sh` sweep. Results land under the new node's fingerprint and become
   directly comparable via `scripts/aggregate.py`.

## Raw data retention

Raw GuideLLM bundles (`results/**/data/`) are gitignored to keep the repo light. The committed
`results.tsv` + `logbook.md` are the durable record. Optionally, raw bundles can be published as
GitHub Release assets or an HF dataset per milestone — decided per project, not by default.
