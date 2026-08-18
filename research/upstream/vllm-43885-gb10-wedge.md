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

Note `py-spy` is not installed in the vLLM container by default; run it from the host against the
container PID (the host `pgrep -f 'VLLM::EngineCore'` sees it), or `docker exec` after
`uvx --from py-spy py-spy`. **Verify this works BEFORE the next wedge** — a wedge is a rare,
time-limited window and fumbling the capture wastes it.

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
