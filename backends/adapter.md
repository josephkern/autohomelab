# Backend adapter contract

A backend adapter knows how to take a **runbook serving config** and a **node profile** and bring
up an **OpenAI-compatible endpoint** for one model — then tear it down. The rest of autohomelab
(bench, tune, aggregate) only ever talks to that endpoint, so adding a new backend never touches
those layers.

Scope today: **NVIDIA only**. vLLM is the first and reference implementation
(`backends/vllm/`). Future candidates: SGLang, TGI, llama.cpp-server.

## Files per backend

```
backends/<name>/
    adapter.sh      # the implementation (see interface below)
    image.lock      # pinned image: full ref + sha256 digest + the versions it contains
```

## Interface

`adapter.sh` is invoked as `adapter.sh <verb> [args]` and must implement:

| Verb | Args | Behavior |
|---|---|---|
| `up` | `<runbook.sh> <node_profile.json>` | Launch the server (pinned image, GPUs attached). Source the runbook for config. Block until `/v1/models` is healthy or fail non-zero. Print the base URL on stdout. |
| `health` | — | Exit 0 iff `/v1/models` responds. |
| `down` | — | Stop and remove the server cleanly. |
| `info` | — | Print `backend` string for results.tsv: `<name>@<ver>(img:sha256:<short>)`. |
| `peakmem` | — | Print peak GPU memory in GB observed since `up` (best-effort). |

## Contract rules

- **No nightlies.** The image is pinned by digest in `image.lock`; `up` must run that digest.
- The endpoint must be OpenAI-compatible (`/v1/models`, `/v1/completions`,
  `/v1/chat/completions`) so GuideLLM and litellm work unchanged.
- A runbook `.sh` only sets shell variables / flags; the adapter decides how to pass them to the
  server. This keeps runbooks backend-portable in principle.
- `up` is idempotent-ish: calling `up` when something is already bound should `down` first or
  fail clearly, never silently attach to a stale server.
