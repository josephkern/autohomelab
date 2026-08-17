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
