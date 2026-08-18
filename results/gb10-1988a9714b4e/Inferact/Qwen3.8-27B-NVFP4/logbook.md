# Logbook — Inferact/Qwen3.8-27B-NVFP4 on gb10-1988a9714b4e

Campaign branch: `autoresearch/qwen3.8-27b-nvfp4`.
Objective: **median c16 tok/s, chat(512/256)**, N=3, KEEP rule = **>3%** over current best.

## Environment (AGENTS rule #3)

| item | value |
|---|---|
| node_fp | `gb10-1988a9714b4e` (NVIDIA GB10, sm_121, aarch64, ~121.6 GiB unified LPDDR5X) |
| driver | 580.173.02 |
| CUDA | 13.0 |
| vLLM | **0.27.1** — `vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967` |
| GuideLLM | 0.6.0 (project pin) |
| model | `Inferact/Qwen3.8-27B-NVFP4`, revision `6128240ebaf4eaa7bad2b3d1c72c37d677c5f462` |
| arch | `qwen3_5` hybrid — **48 of 64 layers Gated DeltaNet**, 16 full-attention |
| baseline runbook | `runbooks/Inferact/Qwen3.8-27B-NVFP4/baseline.sh` (config_hash `92de8fb3`) |

vLLM 0.27.1 was pulled specifically for this campaign; `image.lock` records the capabilities diff
vs 0.25.0. Of the 14 flags 0.27.1 adds, four are hybrid/Mamba tuning dimensions that did not exist
before (`--use-replayssm`, `--replayssm-buffer-len`, `--mamba-ssu-algorithm`, `--kda-prefill-backend`)
— directly applicable to this arch, and the reason 0.27.1 was worth the pull.

## Session 1 — 20260815: baseline, all three gates green

`scripts/suite.sh baseline.sh` → `SUITE-92de8fb3.md`.

- **Gate 1 works:** PASS (functional 4-check).
- **Gate 2 good:** `gsm8k=97.0` (think-off), `mmlu=82.61` (think-on, loglikelihood),
  `mmlu_pro=67.79` (think-off). All at `LIMIT=100`.
- **Gate 3 fast:** chat c1 10.34 / c16 116.63 / c32 177.34; coder c1 12.62 / c16 82.98 / c32 102.02.

Note the baseline still **scales at c32** on the chat shape (+52% over c16), matching the GB10
lab note that chat has headroom past c16 while coder saturates.

## Session 2 — 20260816: MTP depth bracket (wave 1)

One change per candidate: `--speculative-config '{"method":"mtp","num_speculative_tokens":N}'`.
Bracketed n=2 (the published Spark Arena recipe value for this exact model) in both directions,
then extended past it because n=3 kept winning.

| candidate | c16 med | c1 med | vs baseline c16 |
|---|---|---|---|
| baseline (no MTP) | 116.63 | 10.34 | — |
| mtp n=1 | 151.63 | 15.81 | +30.0% |
| mtp n=2 | 150.98 | 16.86 | +29.5% |
| **mtp n=3** | **167.66** | 17.58 | **+43.8%** ← KEEP |
| mtp n=4 | 158.04 | 18.23 | +35.5% |
| mtp n=5 | 150.70 | 15.72 | +29.2% |

**MTP is the whole campaign.** +43.8% c16 and +70% c1 over baseline; every other lever tested since
has been noise by comparison.

Two observations worth carrying forward:

- **The depth optimum is genuinely at 3, and it is not monotone.** n=1/n=2 sit together at ~151,
  n=3 jumps to 168, n=4 falls back to 158, n=5 to 151. A single-point test at the published n=2
  would have left 11% on the table.
- **The c1 and c16 optima differ:** n=4 has the best c1 (18.23) while losing 5.7% at c16. Same
  "speculation depth optimum moves shallower as batch grows" pattern recorded for FF711 on
  llama.cpp — here the c16 objective picks 3, but a latency-first deployment would pick 4.

## Session 2 (cont.) — 20260816: wave 2, five one-change variants off the n=3 winner

Reference = mtp-n3 at **167.66**. KEEP threshold = >3% ⇒ >172.7.

| candidate | c16 med | vs n3 | peak_gb | verdict |
|---|---|---|---|---|
| `--kda-prefill-backend flashkda` | 168.06 | +0.24% | 71.0 | DISCARD (noise) |
| `--max-num-batched-tokens 16384` | 167.85 | +0.11% | 70.2 | DISCARD (noise) |
| `--enable-prefix-caching` | 166.76 | −0.54% | 70.5 | DISCARD (noise) |
| `--gpu-memory-utilization 0.6` | 166.69 | −0.58% | 82.1 | DISCARD (noise) |
| `--kv-cache-dtype fp8` | 166.13 | −0.91% | 69.6 | DISCARD (noise) |

**A clean sweep of negatives — all five inside ±1%, nowhere near the 3% bar.** The tune loop has
converged on plain mtp-n=3.

Findings from the sweep that outlive the candidates themselves:

- **`--kv-cache-dtype fp8` now serves cleanly on 0.27.1.** It crashed at c16 back on 0.22.0 (the
  long-standing "retest fp8 KV" follow-up) — that item can be closed as *works, but buys nothing
  here*. Expected, in hindsight: only 16 of 64 layers are full-attention, so KV is tiny (baseline
  showed 371,565 KV tokens ≈ 45× the c16 concurrency at ctx 8192). **KV pressure is not what
  limits c16 on this arch**, so halving KV bytes has nothing to give back.
- **`--gpu-memory-utilization 0.6` cost 12.2 GB of the shared pool (peak_gb 69.9 → 82.1) for
  −0.6% throughput.** On a unified-memory node that is a pure downside — more OS contention, no
  gain. Confirms the same "KV is not the constraint" conclusion from the other direction.
- **The batched-token confound did not resolve as hypothesised.** Every spec-decode serve here
  warns `max_num_scheduled_tokens is set to 2048 based on the speculative decoding settings …
  consider increasing max_num_batched_tokens`. Raising `--max-num-batched-tokens` to 16384 moved
  the objective +0.11%. So either the scheduler budget was never the binding constraint, or the
  clamp is not lifted by that flag — 0.27.1 adds a *separate* `--max-num-scheduled-tokens` knob
  which is the quantity the warning actually names. **Untested; the one loose thread left.**
- Prefix caching was expected to be flat (GuideLLM synthetic prompts share no prefix) and was. It
  is worth keeping at promote time for real serving traffic despite being bench-neutral, but that
  is a deployment judgement, not a measured win.

## Status

Winner = `20260816_mtp-n3_tuned.sh` (config_hash `dd2f3eef`). Tune loop closed; proceeding to
finalize (program.md §3).

**Power outage 20260816→20260817** took the box down after the last wave-2 bench completed
(20260816-2216). No run was lost mid-flight and no partial bundle was left on disk; the wave-2
results above were committed on 20260817 after the box came back.

## Session 3 — 20260817/18: finalize + promote

`FULL=1 scripts/suite.sh 20260816_mtp-n3_tuned.sh` (cfg `dd2f3eef`) → `SUITE-dd2f3eef.md`.
Promoted as **`VLLM-27-Inferact_Qwen3.8-27B_NVFP4_final.sh`** (`VLLM_TAG=27` passed explicitly to
dodge the known promote.sh version-derivation bug).

### Gates

| gate | finalize | baseline reference | verdict |
|---|---|---|---|
| 1 works | **PASS** (4/4) | PASS | == |
| 2 gsm8k (FULL, think-off) | **95.45** | 97.0 @ n=100 | within noise |
| 2 mmlu_pro (FULL, think-off) | **66.81** | 67.79 @ n=100 | within noise |
| 3 chat c16 | **171.12** | 116.63 | **+46.7%** |
| 3 coder | see curve below | — | valid on re-measure |

Both quality numbers are FULL-dataset against 100-sample references, so the ~1 pt deltas are inside
the reference's own sampling error (binomial SE at n=100 is ~4 pts). Expected: vLLM MTP is
greedy-lossless. **No loglikelihood `mmlu` number exists for this config and cannot** — see the
suite bug below.

### Coder curve: MTP's benefit decays with concurrency and inverts at c32

| level | baseline | mtp-n3 final | delta |
|---|---|---|---|
| c1 | 12.62 | 19.47 | +54.3% |
| c4 | 32.21 | 51.19 | +58.9% |
| c8 | 54.65 | 80.96 | +48.1% |
| c16 | 82.98 | 88.56 | +6.7% |
| c32 | 102.02 | 96.88 | **−5.0%** |

On the long shape, speculative work competes for compute against an already-saturated batch, so the
MTP win erodes from +54% at c1 to −5% at c32. **Deployment caveat for the promoted config:** it is a
large win for interactive/low-concurrency long-context use and a slight loss for c32 batch
long-context throughput. The chat shape does not show this inversion (c32 177.34 → 214.33, +20.9%).

### Two harness defects found and fixed this session

1. **`suite.sh` ran loglikelihood `mmlu` on a spec-decode config.** `REASONING` and `SPEC` were tested
   as mutually exclusive `if/elif` with reasoning FIRST, so a runbook that is BOTH — every promoted
   reasoning model carrying MTP, including this winner — took the reasoning branch and the
   spec-decode skip was unreachable. Symptom: 56,168 requests (14,042 × 4 choices) emitting
   `400 Out of range float values are not JSON compliant: nan` for 1h15m while still advancing its
   progress bar, because lm-eval retries and continues. It would have completed and reported a score
   over whatever subset avoided a NaN. Fixed (commit `2f4a5eb`); for reasoning+spec there is no
   thinking-ON quality task available at all, so Gate 2 is entirely the generative think-off pass.
2. **`suite.sh` applied chat's `MAX_SECONDS=180` to the coder shape**, producing a VOID first coder
   sweep: successful/incomplete per level `c1 3/0, c4 9/3, c8 12/7, c16 10/16, c32 2/31`, giving a
   non-monotonic curve (c8 70.88 > c16 68.88) whose c32 figure of 256.19 was the mean of TWO
   requests. Chat at the same setting was fine (12/46/72/113/136) — the default is only unsafe for
   the long shape, which is why it survived. Fixed (commit `c83624a`): per-shape budgets with
   `MAX_SECONDS_CODER=600`. Re-measure drained 8/30/46/51/51 and is the curve above. The void row
   (`20260817-201312-coder`) is kept, marked `discard`, with its counts in the notes.

AGENTS.md carried the "180s is NOT universal" lesson from the FF711 campaign, but the executable
default had never been changed to match — the documented rule and the code disagreed, and the code
won silently. **Lesson recorded: confirming a guard's condition fires is not the same as confirming
its branch is reachable.**

### Campaign result

Winner = MTP n=3, **+46.7% c16 chat** over baseline with quality neutral. Grammar/tool-call smoke
passed on an MTP+reasoning config across three independent serves — the retest `image.lock` asked
for on the tracked xgrammar × reasoning-parser × MTP bug (0.27.0 #44993). Campaign closed.
