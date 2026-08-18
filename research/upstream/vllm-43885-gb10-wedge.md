# vLLM #43885 — GB10 EngineCore wedge (stuck CUDA stream)

**Upstream:** https://github.com/vllm-project/vllm/issues/43885
*"[Bug]: Qwen3.6-27B-FP8 on GB10: get_output() spin-loop on stuck CUDA stream during prefill burst
(run<6, KV<5%)"* — open since 2026-05-28, 8 comments, label `bug`.

**Status here: NOT POSTED (user decision, 20260818).** The draft below is kept ready. If we hit the
wedge again → run the forensics protocol, attach the artefacts, then post.

---

## Why we think it is the same bug (and why that is not yet proven)

Their signature, on the same silicon: EngineCore spin-loops at ~99% CPU in
`vllm/v1/worker/gpu_model_runner.py::get_output()` waiting on a GPU forward-pass that never returns;
`/v1/models` still answers while `/v1/chat/completions` hangs; `nvidia-smi` utilisation pinned high
with **abnormally low power** (19 W vs 36 W healthy at the same utilisation).

Ours matches externally — zero throughput, requests stuck with `Waiting: 0`, no crash, no
`EngineDeadError`, GPU pinned at high util with 15–30 W, container-scoped (a `docker stop` frees it,
no host reboot). **But we have never captured a stack at wedge time**, so "same bug" is
symptom-matching, not evidence. Closing that gap is the entire point of the protocol below.

## FORENSICS PROTOCOL — run this the next time a wedge is detected

`bench.sh`'s stall-watchdog trips after `STALL_SECS`=90 of `generation throughput: 0.0 … Running: N`.
**Before** it tears the container down, capture:

1. **Python stack of the engine core — the single most valuable artefact:**
   `py-spy dump --native --pid $(pgrep -f 'VLLM::EngineCore')`
   Confirms (or refutes) that we are parked in `get_output()`. Without this we cannot claim their bug.
2. **All threads, in case the hot thread is not the interesting one:**
   `py-spy dump --native --locals --pid <EngineCore pid>`
3. **GPU state:** `nvidia-smi -q` (full dump, not the csv query) + `nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.sm,temperature.gpu --format=csv -l 1 -c 10`
4. **Container log tail:** `docker logs --tail 500 ahl-vllm` — the last scheduler lines before 0.0 tok/s.
5. **Context:** model + revision, pinned image digest, vLLM version, exact runbook flags, the
   concurrency LEVEL, shape, and the running/waiting/KV% from the last healthy log line.
6. Record whether `docker stop` alone recovered it (it always has so far — worth confirming each time).

### VERIFIED capture method (tested end-to-end 20260818) — the host route does NOT work

Both host paths are closed on this node: `sudo -n` requires a password, and
`/proc/sys/kernel/yama/ptrace_scope=1` restricts tracing to descendants while EngineCore is a
root-owned process in a container namespace. `docker exec` alone also fails — Docker withholds
`CAP_SYS_PTRACE` and its seccomp profile blocks ptrace, giving
`Error: Failed to copy Py_Version symbol ... Permission denied (os error 13)` even as root inside
the container. **Working recipe:**

```bash
# 1. serve with ptrace enabled (adapter.sh AHL_PTRACE=1 adds --cap-add=SYS_PTRACE
#    --security-opt seccomp=unconfined; OFF by default so normal runs stay byte-identical)
AHL_PTRACE=1 scripts/serve.sh <runbook>
docker inspect -f 'CapAdd={{.HostConfig.CapAdd}}' ahl-vllm   # expect [CAP_SYS_PTRACE]

# 2. py-spy is not in the image
docker exec ahl-vllm pip install -q py-spy

# 3. find the CONTAINER-side pid (differs from the host pid)
CPID=$(docker exec ahl-vllm sh -c 'ls /proc | grep -E "^[0-9]+$" | while read p; do \
  c=$(tr "\0" " " < /proc/$p/cmdline 2>/dev/null); case "$c" in *EngineCore*) echo $p;; esac; done' | head -1)

# 4. capture
docker exec ahl-vllm py-spy dump --pid "$CPID"
```

**A wedge cannot be captured unless the serve was ALREADY started with `AHL_PTRACE=1`** — the
capability cannot be added to a running container. For any run where a wedge is plausible (full
sweeps, c1/c16 on the long shape), serve with it on.

### HEALTHY-STATE CONTROL STACK (unsloth/Qwen3.8-27B-NVFP4, MTP n=3, mid c16 bench, 3/3 samples)

This is the baseline to diff a wedged stack against. Note it is **NOT** `get_output()`:

```
Thread (active): "MainThread"
    seq_lens_cpu (vllm/v1/attention/backend.py:515)
    build (vllm/v1/attention/backends/flashinfer.py:1234)
    build_for_drafting (vllm/v1/attention/backend.py:754)
    build_per_group_and_layer_attn_metadata (vllm/v1/spec_decode/llm_base_proposer.py:999)
    propose (vllm/v1/spec_decode/llm_base_proposer.py:707)
    propose_draft_token_ids (vllm/v1/worker/gpu_model_runner.py:5268)
    sample_tokens (vllm/v1/worker/gpu_model_runner.py:4658)
    step_with_batch_queue (vllm/v1/engine/core.py:671)
    _process_engine_step (vllm/v1/engine/core.py:1439)
    run_busy_loop (vllm/v1/engine/core.py:1386)
```

Under healthy load with MTP the engine core sits in **spec-decode draft attention-metadata
construction**, not in a generic output wait. If a wedged stack shows `get_output()`, that is a clean
diff and direct evidence for #43885. Caveat: `py-spy dump` shows the Python frame, not whether it is
computing or blocked; `seq_lens_cpu` looks like a device->host copy, so this frame may itself be a
synchronisation point. `py-spy record` (proportions) or `--native` (C stack) would resolve that.

## Our data (as of 20260818) — 10 events, one node

| date | model | vLLM | level | power at wedge |
|---|---|---|---|---|
| 2026-06-13 | Qwen3-8B-NVFP4 | 0.22.0 | c32 | 15 W |
| 2026-06-13 | Qwen3-8B-NVFP4 | 0.22.0 | c16 | 26 W |
| 2026-06-13 | Qwen3-8B-NVFP4 | 0.23.0 | c16 | 21 W |
| 2026-06-14 | Qwen3.6-35B-A3B-NVFP4 | 0.23.0 | c16 | 24 W |
| 2026-06-14 | Qwen3.6-35B-A3B-NVFP4 (coder) | 0.23.0 | c16 | 30 W |
| 2026-06-16 | Nemotron-3-Super-120B-A12B-NVFP4 (coder) | 0.23.0 | **c1** | 19 W |
| 2026-07-04 | Qwen3.6-35B-A3B-NVFP4 | 0.24.0 | c16 | 21 W |
| 2026-07-12 | Qwen3.6-35B-A3B-NVFP4 | 0.24.0 | c16 | 23 W |
| 2026-07-12 | Qwen3.6-35B-A3B-NVFP4-Fast | 0.25.0 | **c1** | 18 W |
| 2026-07-12 | Qwen3.6-35B-A3B-NVFP4-Fast | 0.25.0 | c16 | 27 W |

**Two findings that would be new to the thread:**
- **It fires at concurrency 1** (2 of 10, both on the 4096/1024 shape). The issue author saw a wedge
  below their `--max-num-seqs 6` cap; c1 is the limit case. Batch occupancy is not the trigger.
- **It spans four minor versions** (0.22.0 → 0.25.0, 2026-06-13 → 07-12) and four models, all
  **NVFP4/compressed-tensors** rather than their FP8. Not a recent regression, not model-specific.

Caveats to carry into any post: no stack captured (see above); power numbers are harness samples and
`nvidia-smi` reports `memory.total` as `[N/A]` on GB10 so some fields are proxies; the 2026-06-13 c16
event ran `--kv-cache-dtype fp8_e4m3`, which we suspect independently on sm_121, so it is excluded
from the "not model-specific" claim; all ten were incidental — we have never reproduced deliberately.

**No wedge observed on 0.27.1 yet** (current campaigns), but exposure there is much smaller — that is
not evidence of a fix. The two MTP n=4 crashes on 20260818 are a DIFFERENT failure (container death
with ~110k errored requests, not a silent hang) and should not be conflated.

## Related upstream issues found in the same search

- **#49210** — EngineCore *livelock* (100% CPU, no crash) with MTP spec-decode + xgrammar structured
  outputs, regression from 0.24.0. Different trigger, same "100% CPU, no crash" class. Relevant to us
  because it is the same three-way interaction we already track (xgrammar × reasoning-parser × MTP).
- **#50934** — CUDA misaligned-address crash on GB10 sm_121 after ~10 days uptime, NVFP4 + Marlin MoE
  + MTP. 0 comments, unconfirmed. Adjacent to our MTP n=4 crashes but the timescale differs by orders
  of magnitude (minutes vs days).
- **#43702** — `[RFC]: Non-blocking core model loop`. Confirms the engine core **blocks** when idle
  (`multiprocessing.Queue.get(block=True)`), so EngineCore at ~100% CPU during active serving is
  EXPECTED single-threaded work, not a spin. Use this to distinguish normal from pathological: the
  pathological cases all have **zero throughput**.

---

## DRAFT COMMENT (ready to post after forensics are attached)

**Independent reproduction on a second GB10 node — 10 wedges across 4 models and 4 vLLM versions, including two at concurrency 1**

We hit what looks like the same wedge on a separate DGX Spark (GB10) node, on a different model family and quantization than the report. Posting our data because two details may narrow the search: it is **not concurrency-dependent**, and it is **not version-specific**.

**Environment**
- NVIDIA GB10 (DGX Spark), sm_121, aarch64, ~122 GB unified LPDDR5X
- Driver 580.159.03 -> 580.173.02, CUDA 13.0, kernel 6.17.0-10xx-nvidia
- `vllm/vllm-openai` official images, pinned by digest: v0.22.0 `0fec7ec5f3e6`, v0.23.0 `6d8429e38e37`, v0.24.0 `251eba5cc7c1`, v0.25.0 `fc56161ee42a`
- Models: Qwen3-8B-NVFP4 (dense), Qwen3.6-35B-A3B-NVFP4 (MoE), Nemotron-3-Super-120B-A12B-NVFP4 (MoE), Qwen3.6-35B-A3B-NVFP4-Fast — all **NVFP4/compressed-tensors**, not FP8
- Load generator: GuideLLM 0.6.0, `--profile concurrent`, one process per concurrency level

**Signature** matches the report: generation throughput -> 0.0 tok/s with requests stuck and `Waiting: 0`, no crash, no `EngineDeadError`, no watchdog trigger. `/v1/models` keeps answering. GPU utilisation counter pinned high with **abnormally low power draw — 15-30 W at wedge**, against 33-44 W when healthy under the same load. `docker stop` frees the GPU instantly; **no host reboot or GPU reset needed**, so it is container-scoped.

**The two findings we think are useful**

**1. It fires at concurrency 1.** Two of our ten events wedged with a single in-flight request:

| date | model | vLLM | level | power at wedge |
|---|---|---|---|---|
| 2026-06-16 | Nemotron-3-Super-120B-A12B-NVFP4 | 0.23.0 | **c1** | 19 W |
| 2026-07-12 | Qwen3.6-35B-A3B-NVFP4-Fast | 0.25.0 | **c1** | 18 W |

Both on the long-prompt shape (4096-token prompt / 1024-token output). The report notes a wedge below the `--max-num-seqs 6` cap; c1 is the strongest form of that. Whatever the trigger is, batch occupancy is not it.

**2. It spans four minor versions.** 0.22.0, 0.23.0, 0.24.0 and 0.25.0 all wedged, across 2026-06-13 -> 2026-07-12. Not a recent regression, and not fixed in that window. Distribution: c32 x1, c16 x7, c1 x2.

**One thing that helped but did not fix it.** Our first wedge was at a c16->c32 stage transition inside a single multi-rate GuideLLM run. Splitting the sweep into one process per concurrency level — same total load, same durations — stopped the c32 case reproducing. It did **not** stop the wedge generally: the nine later events all occurred with per-level isolation in place. So load *transitions* may raise the probability without being necessary.

**Caveats, stated plainly.** We have **not** captured a py-spy or gdb stack at wedge time, so we cannot confirm ours is the same `get_output()` spin-loop rather than a different path with the same external symptoms — treat the "same bug" claim as unconfirmed. Our power figures are harness samples at crash time, and `nvidia-smi` on GB10 reports `memory.total` as `[N/A]`, so some fields are proxies. One event (2026-06-13, c16) ran `--kv-cache-dtype fp8_e4m3`, which we suspect independently on sm_121; we've excluded it from the "not model-specific" claim. We have never reproduced deliberately — all ten were incidental to benchmark runs. We have no wedge on 0.27.1 yet, but far less exposure there, so that is not evidence of a fix.

**Offer:** we run automated sweeps on this node regularly and have a stall-watchdog that detects the wedge within 90 s. If a `py-spy dump --native` on the `VLLM::EngineCore` PID plus `nvidia-smi -q` at wedge time would help, we can wire that into the watchdog and post the next occurrence.
