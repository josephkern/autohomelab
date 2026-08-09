# DavidAU/Qwen3.6-27B-Fable-Fusion-711-…-NEO-MAX-MTP-GGUF — GB10 campaign

Creative-writing / uncensored (Heretic ARA-abliterated) fine-tune of Qwen3.6-27B, served from
DavidAU's **NEO-MAX imatrix GGUF** quants on the new **llama.cpp host-process backend**.

**Campaign status: COMPLETE (with documented gaps) 20260809 — winner = the launcher defaults.**
**Gate 1 PASS · Gate 2 PARTIAL (gsm8k 99.0 @LIMIT=100; mmlu_pro deferred) · Gate 3 PASS chat, coder
invalid, c32 uncharacterized.** See "Remaining gaps" and the promotion note at the bottom.

## Environment (AGENTS rule 3)

| | |
|---|---|
| node_fp | `gb10-1988a9714b4e` (NVIDIA GB10, sm_121, aarch64, ~121.6 GiB unified LPDDR5X) |
| driver | 580.173.02 |
| CUDA | 13.0 (nvcc V13.0.88) |
| backend | **llama.cpp @ `0865990`**, built `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121` (`scripts/build_llamacpp.sh`) |
| GuideLLM | 0.6.0 (pinned) |
| model repo | `DavidAU/…-NEO-MAX-MTP-GGUF` @ `674415bfad8eaf3d55bbe5ce2e6bb01ee211c380` |
| tokenizer | `DavidAU/…-NM-DAU-MTP` @ `b7676ecef7d1adcabfdc1b42a389f8643c7723fb` (GGUF repos ship none) |
| launcher | `launchers/LCPP-DavidAU_Qwen3.6-27B-FF711_NEO-MAX-MTP.sh` |
| repo commit | `649abfe` (backend scaffolding) |

## Why llama.cpp and not vLLM

The requested artifact is GGUF. vLLM cannot serve it: arch `qwen35` is a hybrid
linear/full-attention VL model with an MTP head, far outside vLLM's narrow GGUF loader. The repo's
only pre-existing GGUF path (`bench_ds4.sh`) is bound to antirez's ds4 engine, which implements the
DeepSeek-V4 architecture only. So this campaign also **adds llama.cpp as a general GGUF backend** —
see AGENTS.md → "HOST-PROCESS backends (GGUF)".

vLLM-servable NVFP4/FP8 conversions of this same fine-tune do exist (`maci0/…-MTP-NVFP4` W4A4 20.6 GB,
`kkuspa/…-NVFP4A16` 28.6 GB) and remain the obvious cross-backend comparison — **not run.**

## Model shape (from the bf16 source `config.json`)

- Dense 27B, 64 layers, `hidden_size` 5120, vocab 248320, native ctx 262144.
- **Hybrid attention:** `linear_attention` ×3 then `full_attention` every 4th layer. Only the 16
  full-attention layers hold a growing KV cache (~64 KiB/token); the 48 linear layers carry a
  constant-size recurrent state per slot. KV is therefore cheap — 196608 total ctx ≈ 12.6 GiB.
- **MTP:** `mtp_num_hidden_layers: 1`. DavidAU embeds the MTP tensors in the `-MTP-` GGUFs at Q8_0.
- VL model (vision tower + `mmproj-*.gguf`); served **text-only**, matching our text suite and the
  `unsloth/Qwen3.6-27B-NVFP4` vLLM runbook's `--limit-mm-per-prompt image:0`.

## Engine findings (worth keeping)

1. **MTP engages via `--spec-type draft-mtp`.** The obvious `--mtp` flag is **download-only**
   (`LLAMA_EXAMPLE_DOWNLOAD` in `common/arg.cpp`) and silently does nothing on the server. Because
   the NextN tensors are embedded, **no `-md` draft file is needed** — llama.cpp gates loading them
   on the spec type (`src/models/qwen35.cpp`, `mtp_flags` / `ml.load_mtp`). Confirmed in the log:
   `common_speculative_init_result: creating MTP draft context against the target model`.
2. **MTP acceptance ≈ 0.75**, well above the model card's claimed ~60%. Observed range 0.54–0.90,
   mean accepted length ~2.5 at `--spec-draft-n-max 2`, measured at temp 0 (MTP's best case; the
   card warns acceptance degrades above temp 1). → **`MTP_DRAFT=3` is a live candidate.**
3. **`-np` is a correctness trap for benchmarking.** llama.cpp serves from a fixed pool of slots;
   requests beyond `-np` **queue** rather than batch. Benchmarking c16 against a `-np 1` server
   measures the queue and reports a plausible-looking but meaningless number. Launcher defaults
   `NP=16`; `bench_llamacpp.sh` warns when `LEVELS_SET` exceeds the running server's `-np`.
4. **Launcher restart race (found + fixed).** A server with in-flight slots takes ~30 s to cancel
   them and release the port. The original fixed `sleep 2` raced the replacement into a bind
   failure that presented as a silent startup hang. `stop_prior` now polls for both process exit
   and port release, then escalates to SIGKILL. The log is also **appended, never truncated** — a
   draining server holds its fd open and a truncating redirect leaves it writing at a stale offset.

## Gate 1 — works (smoke): **PASS 4/4**

`scripts/smoke.sh` against Q5_K_M MTP. Chat / structured JSON / tool-call / reasoning routing all
pass. Serving flags `--jinja` (tool calling) + `--reasoning-format deepseek` (CoT → separate
channel). Verified the split directly rather than trusting the aggregate check:
`content: '391'`, `reasoning_content: 'Thinking Process:…'` (929 chars) — no `<think>` leak.

## Gate 2 — good (accuracy)

Reasoning model, so generative tasks run on a **thinking-OFF serve** (`THINK_OFF=1` →
`--chat-template-kwargs '{"enable_thinking": false}'`, evaluated with `THINK=off`). Probed before
trusting scores (AGENTS.md requires this per-arch — NemotronH generates zero tokens on this path):
content `'72'`, reasoning empty. **Honored.**

| task | this model (Q5_K_M MTP) | reference: `unsloth/Qwen3.6-27B-NVFP4` (vLLM `_final`) |
|---|---|---|
| gsm8k (LIMIT=100, think-off) | **99.0** strict == flexible | 98 |
| mmlu_pro | **not run** | 71.6 |
| mmlu (loglikelihood) | **not run** | 84.3 |

gsm8k **99.0 with strict == flexible** — no truncation inversion, so the think-off path is clean.
The NEO imatrix Q5_K_M matches/beats the NVFP4 build of stock Qwen3.6-27B on this task. Note the
scores are not a matched pair (different session, different base fine-tune), so treat as indicative.

**mmlu_pro was cut at ~904/1400 requests** (~55 min in) and no partial row was written. It costs
~1 h per config here, so the plan is: **gsm8k as the in-loop quality reference across quants,
mmlu_pro once on the winner at finalize.** This matches AGENTS.md's split between the in-loop
reference and the finalize suite.

⚠️ **Untested:** whether loglikelihood `mmlu` works at all under llama.cpp MTP. Under vLLM,
spec-decode returns NaN prompt_logprobs and loglikelihood tasks 400 (AGENTS.md). If llama.cpp
behaves the same, the quality gate here is generative-only — which is the correct gate for a
spec-decode config anyway.

## Gate 3 — fast (throughput): **PASS** (chat) / coder INVALID, re-run needed

Session 20260809 (repo `a52c39f`…`f2898d4`). Baseline = the launcher's defaults, Q5_K_M MTP
draft=2 np=16, N=3 median, chat(512/256), `MAX_SECONDS=180`, greedy:

**c16 63.51 · c1 19.09** (per-run c16 62.3 / 65.2 / 63.51; c1 spread ≤1.4%)

Finalize sweep (single run, fresh serve) — `1,4,8,16` only; **c32 omitted deliberately**: llama.cpp
QUEUES past `-np`, so c32 against a 16-slot server measures the queue, not the engine.

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 18.88 | 28.02 | 36.05 | **70.32** | not run (np=16) |
| coder(4096/1024) | ~~27.57~~ | ~~121.23~~ | ~~47.72~~ | ~~56.42~~ | — |

Reference, stock `unsloth/Qwen3.6-27B-NVFP4` on vLLM, same node (`VLLM-23-…_final`, MTP n=1):
baseline c1 12.1 / c16 122.6; MTP n=1 **c1 16.85 / c16 161.5**. So this GGUF **beats vLLM at c1
(+13%)** and loses ~2.3× at c16 — see the bandwidth analysis below. Not a matched pair (different
fine-tune AND different engine); directional only.

### ⚠ The coder row is INVALID — a methodology failure worth remembering

`results.tsv` row `20260809-190152-coder` is marked `discard`. Successful-request counts per level
were **c1=3, c4=4, c8=2, c16=5** (3–15 `incomplete`). At 4096/1024 on a ~20 tok/s dense model a
single request needs ~50 s, so a 180 s stage never drains; GuideLLM's
`output_tokens_per_second.successful.mean` is then an average over a handful of lucky completions
and goes **non-monotonic (c4 121.23 > c8 47.72)**. AGENTS.md's "`--max-seconds ~180`" was calibrated
on much faster models. **The coder shape on a slow dense model needs `MAX_SECONDS>=600`.** Chat is
unaffected: 39–42 successful at c16 with mean output 244–252 tokens across every run.

### ⚠ Session drift at c16 (~10%) exceeds the +3% KEEP threshold

The finalize sweep measured **c16 70.32** for the *same config* the tune loop medianed at **63.51**
(+10.7%). Ruled out as a sampling artifact — sample counts (42 vs 39/42/40) and mean output lengths
(252 vs 244–249) match. The likely cause is memory/page-cache state: the tune loop cycled four
different 18–24 GB GGUFs (84 GB total) and ended in a swap event, while the finalize run started
from a fresh serve with 77 GB available. **Consequence: c16 differences below ~10% across sessions
are not trustworthy here**, which is why every candidate below is reported as *not separable* rather
than *worse*. c1 is well-behaved and is the axis to trust (see the bandwidth fit).

## Tune loop — COMPLETE. Winner = the baseline (no candidate cleared the bar)

Driven by `research/run-queue-ff711-llamacpp.sh` (one-axis ablations) on
`scripts/run_experiment_llamacpp.sh` (relaunch → smoke-gate → N=3 → median). All N=3, chat, c16
objective vs the same-session baseline **c16 63.51 / c1 19.09**.

| candidate | c16 | Δc16 | c1 | Δc1 | verdict |
|---|---|---|---|---|---|
| **baseline** Q5_K_M MTP d2 np16 | **63.51** | — | **19.09** | — | **KEEP (winner)** |
| `mtp-off` regular Q5_K_M | 61.10 | −3.8% | 12.03 | **−37.0%** | discard |
| `mtp-d1` | 64.30 | +1.2% | 16.61 | −13.0% | discard |
| `mtp-d3` | 61.58 | −3.0% | **20.01** | **+4.8%** | discard on c16; best c1 |
| `q4km` Q4_K_M MTP | 63.37 | −0.2% | **20.10** | **+5.3%** | discard on c16; best c1 |
| `q6k` Q6_K MTP | 58.63 | −7.7% | 16.89 | −11.5% | discard |
| `np32` (first attempt) | — | — | — | — | **CONTAMINATED, see below** |

Read this honestly: given ~10% cross-session c16 drift (above), every c16 delta here is inside the
noise floor. The defensible statement is **no candidate separated from the baseline on the
objective**, so the baseline stands by default rather than by demonstrated superiority. The c1
column is the trustworthy one.

### MTP is the single biggest lever (matched-pair isolation)

The `-MTP-` and regular Q5_K_M files differ **only** by the embedded NextN tensors, so this is a
clean A/B: **c1 +58.7% (12.03 → 19.09)**, c16 +3.9%. Unlike vLLM spec-decode, it costs nothing at
batch. `--spec-type draft-mtp` remains mandatory (`--mtp` is download-only — see Engine findings).

### Decode is bandwidth-bound, and the numbers say so precisely

Per-request `draft acceptance` from the server log, aggregated per run:

| run | accept | mean accepted len | c1 |
|---|---|---|---|
| Q5_K_M d2 | 0.675 | 2.35 | 19.09 |
| Q4_K_M d2 | 0.665 | 2.33 | 20.10 |
| Q6_K d2 | 0.672 | 2.34 | 16.89 |
| Q5_K_M **d1** | **0.778** | 1.78 | 16.61 |
| Q5_K_M **d3** | **0.564** | 2.69 | 20.01 |

1. **MTP-off runs at ~93% of the DRAM roofline**: 21.18 GB/token × 12.03 tok/s = 255 GB/s against
   the GB10's 273 GB/s. Pure streaming GEMV; there is no engine headroom left at c1 without
   speculation.
2. **MTP trades bandwidth efficiency for tokens.** With MTP on, apparent throughput is ~172 GB/s —
   *lower*, because the verify pass computes 3 positions instead of 1 and the draft head adds work.
   Net still +58.7%. That is the speculative bargain, visible in the data.
3. **Quant scales as predicted on the Q5→Q6 leg**: +13.5% bytes predicts −11.9% c1, measured
   **−11.5%**. The Q5→Q4 leg under-delivers (+12.6% bytes predicts +12.6%, measured **+5.3%**).
   A two-point fit on Q5/Q6 (~185 GB/s + ~8.7 ms/pass fixed overhead) predicts Q4 at 21.4 vs 20.1
   measured. **Acceptance is NOT the cause** (0.665 vs 0.675 — flat); most likely Q4_K_M dequant
   compute. Small enough to want a repeat before asserting it.
4. **Draft depth trades compute for latency, and the optimum moves shallower as batch grows.**
   Depth 1→3 raises accepted length 1.78→2.69 while acceptance falls 0.778→0.564. At c1 the extra
   tokens win (d3 best); at c16 the extra verify compute loses against an already-saturated batch
   (d1 best). d2 is the midpoint that wins neither end.

### `np32` trap (candidate 4) — DEFERRED, c32 still uncharacterized

The launcher derives `CTX = CTX_PER_SLOT * NP`, so `NP=32` alone **doubled total context** to
393216 (~25 GiB KV instead of 12.6), over-committed unified memory into **swap**, and degraded
mid-run (c1 18.75 → 14.19 between benches; c16 36.28). That is two changes at once *and* a
swapping measurement — row `20260809-183024-chat` is marked `discard`/CONTAMINATED. The corrected
candidate (`NP=32 CTX_PER_SLOT=6144`, constant total ctx) is in the queue script as slug `np32` but
**has not been run**, so **FF711 c32 remains uncharacterized**. Note 6144/slot only just covers
coder(4096/1024).

## Remaining gaps (deliberate, not oversights)

- **Gate 2 at FULL rigor not run.** gsm8k stands at **99.0 (LIMIT=100, think-off, strict==flexible)**
  from the earlier session; `mmlu_pro` and full-set gsm8k were deferred by the operator to free the
  box for the DS4 round-4 campaign. Promotion below rests on the LIMIT=100 gsm8k only.
- **coder shape** needs re-running at `MAX_SECONDS>=600` (see the INVALID note above).
- **c32** needs the corrected `np32` run.
- Whether loglikelihood `mmlu` works at all under llama.cpp MTP is still untested.

## Promotion note

`scripts/promote.sh` is vLLM-specific (it rewrites `VLLM_IMAGE`/`VLLM_FLAGS` runbooks). For this
backend the promoted artifact is **the launcher itself**, with the winning config as its defaults —
same convention as the ds4 launcher.

**PROMOTED 20260809: `launchers/LCPP-DavidAU_Qwen3.6-27B-FF711_NEO-MAX-MTP.sh` unchanged.** The tune
loop's winner *is* the launcher's existing default config (Q5_K_M MTP, `--spec-type draft-mtp`,
`--spec-draft-n-max 2`, `-np 16`, `-c 196608`, `-fa on`, `--jinja`, `--reasoning-format deepseek`),
so promotion is a no-op edit plus this record. Gates: **1 PASS** (4/4, re-run twice this session),
**2 PARTIAL** (gsm8k 99.0 @LIMIT=100; mmlu_pro deferred), **3 PASS chat** (coder invalid, c32 absent).

**Latency variant, documented not promoted:** for single-user interactive use — which is what this
creative-writing model actually serves via OWUI — `MTP_DRAFT=3` gives the best measured c1 (20.01,
+4.8%) for −3.0% c16, and `Q4_K_M` gives 20.10 (+5.3%) at a quality risk that was never eval'd.
The charter's objective is c16, so the default stays at d2/Q5_K_M; flip `MTP_DRAFT=3` if latency
matters more than batch throughput for a given deployment.

## Promotion note

`scripts/promote.sh` is vLLM-specific (it rewrites `VLLM_IMAGE`/`VLLM_FLAGS` runbooks). For this
backend the promoted artifact is **the launcher itself**, with the winning config as its defaults —
same convention as the ds4 launcher.
