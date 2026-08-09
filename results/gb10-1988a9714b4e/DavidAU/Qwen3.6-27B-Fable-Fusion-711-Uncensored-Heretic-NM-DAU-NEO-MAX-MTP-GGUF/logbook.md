# DavidAU/Qwen3.6-27B-Fable-Fusion-711-…-NEO-MAX-MTP-GGUF — GB10 campaign

Creative-writing / uncensored (Heretic ARA-abliterated) fine-tune of Qwen3.6-27B, served from
DavidAU's **NEO-MAX imatrix GGUF** quants on the new **llama.cpp host-process backend**.

**Campaign status: IN PROGRESS — Gates 1 & 2(general) pass; Gate 3 + tune loop not yet run.**

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

## Gate 3 — fast (throughput): **NOT RUN**

Blocked only by wanting a quiesced box. Targets to beat, from the stock `unsloth/Qwen3.6-27B-NVFP4`
vLLM campaign on this node (`VLLM-23-…_final`, MTP n=1):

| | c1 | c16 |
|---|---|---|
| vLLM NVFP4 baseline | 12.1 | 122.6 |
| vLLM NVFP4 + MTP n=1 (`_final`) | **16.85** | **161.5** |

Anecdotal only, from eval traffic (long prompts, 16 concurrent, not a benchmark): ~4.8–6.5 t/s per
slot decode, ~150–285 t/s prompt processing. Do not quote these as results.

## Candidate queue (tune loop — NOT STARTED)

All four quants are downloaded to `~/gguf` (84 GB).

| # | axis | candidate | hypothesis |
|---|---|---|---|
| 1 | MTP | `MTP=0` vs `MTP=1` on the **matched Q5_K_M pair** (`-MTP-` vs regular) | isolates MTP; the two files differ only by the embedded NextN tensors |
| 2 | MTP depth | `MTP_DRAFT=1,2,3` | measured acceptance 0.75 ≫ card's 60% → deeper drafts may pay |
| 3 | quant | Q4_K_M / Q5_K_M / Q6_K (all MTP) | decode is bandwidth-bound on LPDDR5X; smaller quant = higher ceiling, watch gsm8k |
| 4 | slots | `NP` 16 vs 32 | c32 characterization needs NP ≥ 32, else it measures queueing |

Protocol: N=3 median, `LEVELS_SET=1,16`, `MAX_SECONDS=180`, KEEP if median c16 > +3% and gsm8k
holds. `TAG=<slug> scripts/bench_llamacpp.sh <stub> chat coder`.

## Promotion note

`scripts/promote.sh` is vLLM-specific (it rewrites `VLLM_IMAGE`/`VLLM_FLAGS` runbooks). For this
backend the promoted artifact is **the launcher itself**, with the winning config as its defaults —
same convention as the ds4 launcher.
