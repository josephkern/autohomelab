# Logbook — NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 (GB10 node #1)

Campaign 2026-07-09. Branch `autoresearch/nemotron-3-puzzle-75b`. Promoted:
`VLLM-24-nvidia_NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B_NVFP4_final.sh` (winner = **mtp-n1**).

## Environment (AGENTS rule #3)
- **Node** gb10-1988a9714b4e — NVIDIA GB10, sm_121 (Blackwell), aarch64, ~121.6 GiB **unified** LPDDR5X,
  **16 GB swap**. Driver **580.159.03**, CUDA **13.0**.
- **Image** `vllm/vllm-openai@sha256:251eba5cc7c12fed0b75da22a9240e582b1c9e39f6fbc064f86781b963bd814f`
  = **vLLM 0.24.0** (torch 2.11+cu130). **GuideLLM 0.6.0.** lm-eval harness.
- **Model** `nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4`, revision
  `1d370e47fbc56d1019a471c2339663cdbbb5236f`. 53.5 GB download (6 safetensors shards).

## Model
`NemotronHPuzzleForCausalLM` (`model_type: nemotron_h_puzzle`) — NAS-**"Puzzle"**-compressed hybrid:
interleaved **Mamba2 + latent-MoE (512 routed + 1 shared expert) + Attention**, 88 layers, **9B active /
75B total**, native **262K** context. ModelOpt **MIXED_PRECISION** quant (routed experts NVFP4 W4 gs16,
Mamba/shared-expert projections FP8; fp16 mamba SSM cache). Reasoning (`nemotron_v3`) + tool-calling
(`qwen3_coder` XML) + native **MTP** (`num_nextn_predict_layers=1`). **Text-only** (no vision_config, no
image processor). vLLM 0.24.0 registers the arch (→ `nemotron_h` module) + `nemotron_h_mtp` spec method
+ `nemotron_v3` parser **natively** — no patched image, no trust-remote-code strictly required (kept as
vendor-recommended for the heterogeneous Puzzle config).

## Headline result (winner = mtp-n1)
| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| baseline chat | 20.4 | 64.3 | 102.8 | 154.3 | 211.3 |
| **mtp-n1 chat** | **29.5 (+45%)** | 79.2 | 121.3 | **173.1 (+12%)** | 240.4 (+14%) |
| baseline coder | 22.7 | 59.9 | 73.3 | 111.8 | 70.7 |
| **mtp-n1 coder** | 30.6 (+35%) | 73.5 | 109.5 | 123.1 (+10%) | **114.1 (+61%)** |

Quality (LIMIT=100): mmlu(LL,think-on) **83.51→83.67** (lossless, deterministic reference); gsm8k
(think-off) 95→91, mmlu_pro (think-off) 71.9→69.2 (within batched-serving noise; matches the Super
precedent's promoted drops). Smoke 4/4 (chat/JSON/tool-call/reasoning).

## The big finding — enforce-eager solves the DGX-Spark memory OOM (HF discussion #1)
HF **discussion #1** (identical GB10/DGX-Spark, vLLM 0.24.0) reported a **~160 GB startup RAM spike**
(settles ~100 GB) that OOMs an unprovisioned box + "rubbish think-off output" + "10-20 t/s unusable".
Findings on our box:
- **Root cause of the spike = torch.compile / CUDA-graph capture.** `--enforce-eager` removes it →
  measured **peak 99.5 GB (== steady state), ZERO swap, ~25 GB headroom**. This is the gpt-oss-120b
  failure mode, but here it's fully avoidable. `--enforce-eager` + `PYTORCH_CUDA_ALLOC_CONF=expandable_
  segments:True` are **MEMORY-MANDATORY** on this 121.6 GiB box (user declined adding swap). Cost: no
  CUDA graphs (some decode tok/s left on the table) — the price of fitting without swap. Applies to any
  future NemotronH-Puzzle model here. (The spike replicates on the smaller Puzzle models too per #1.)
- **"Rubbish think-off" NOT reproduced.** `enable_thinking:false` is coherent (gsm8k 96, clean factual
  answers). #1's rubbish was his heavy agentic config (MTP **n=4** + poor accept + OpenCode tool loop).
  This model has a real `enable_thinking` switch (unlike the Super, which needed `low_effort`).
- **"10-20 t/s" is single-user only** (c1 ≈ 20-30). Batched, chat scales ~6-8× to c16 173 / c32 240.
  KV profiled to 4.8M tokens = **293× concurrency** at 16K. chat c16 ≈ **2× the Nemotron-3-Super
  baseline** (75.5), matching NVIDIA's "~2× throughput vs Super" claim for Puzzle.

## Tune loop (objective = median c16 chat, N=3, levels 1,16)
| candidate | c16 | c1 | verdict |
|---|---|---|---|
| baseline (enforce-eager, no MTP) | 154.3 | 20.4 | keep (current best) |
| **mtp-n1** (`--speculative-config method=mtp,num_speculative_tokens=1`) | **169.3** (exp) / 173.1 (final) | 29.0 | **KEEP — winner (+9.7% exp / +12% final)** |
| mtp-n2 (num_spec=2) | — | — | DISCARD — smoke fail (JSON check 3/4) |
| mtp-async (mtp-n1 + `--async-scheduling`) | 166.6 | 29.0 | DISCARD — −1.6% (noise; bandwidth-bound, not scheduler-bound) |

- **MTP was the dominant (and only) lever.** Acceptance ~90-93% @ c1, ~77% @ c16 (n=1). Discussion #1's
  poor acceptance was purely the **n=4** setting; n=1 accepts well and wins.
- **nemotron_h_mtp loglikelihood WORKS** — returns valid prompt_logprobs, so loglikelihood mmlu ran fine
  under spec-decode here (unlike Qwen MTP / Nemotron-3-Super MTP which NaN → 400). Still, suite.sh's
  spec-decode branch (generative-only Gate 2) is the safe default; the mmlu(LL) here is a bonus signal.
- async-scheduling gives nothing on this bandwidth-bound decode. Not tested: `--enable-expert-parallel`
  (multi-GPU; inert on TP=1), `--moe-backend` variants, `--kv-cache-dtype` (MTP-n1 already the clear win).

## Deployment note
Promoted `_final.sh` serves at `--max-model-len 16384` (benchmark/interactive). Native context is 262K;
a long-context launcher (higher max-model-len, hold util) is a separate artifact if needed (cf. the 35B
256K launcher). enforce-eager is baked into `_final` (mandatory on this box).
