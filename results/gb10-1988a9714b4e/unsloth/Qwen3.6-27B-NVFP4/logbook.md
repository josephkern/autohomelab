# unsloth/Qwen3.6-27B-NVFP4 — logbook (GB10 node #1)

**STATUS: COMPLETE — promoted `VLLM-23-unsloth_Qwen3.6-27B_NVFP4_final.sh`** (winner = mtp-n1,
qwen3_5_mtp num_spec=1). 2026-06-25. Branch `autoresearch/qwen3.6-27b`.

Dense 27B **multimodal** model (served text-only) with a **preserved MTP head** — the qwen3_5_mtp
lever lands the **largest MTP lift in the project (+31.7% c16)**, and it loads on the **stock 0.23.0
image with no patches** (unlike the qwen3_next NVFP4 saga).

## Environment (AGENTS rule #3)
- node_fp: `gb10-1988a9714b4e` — NVIDIA GB10, sm_121, aarch64, ~121.6 GiB unified LPDDR5X
- driver 580.159.03, CUDA 13.0
- backend: vLLM **0.23.0** STOCK image `vllm/vllm-openai@sha256:6d8429e3` (torch 2.11.0+cu130). GuideLLM 0.6.0.
- model: `unsloth/Qwen3.6-27B-NVFP4` rev `890bdef7a42feba6d83b6e17a03315c694112f2a` (faithful NVFP4
  W4A4 compressed-tensors of Qwen/Qwen3.6-27B, ~26.4 GB; `Qwen3_5ForConditionalGeneration`, dense 27B,
  multimodal, MTP `mtp_num_hidden_layers=1` preserved — `mtp.fc`/`mtp.layers.0`/`mtp.norm` in weights).
- serve flags: TP1, gpu-mem-util 0.5, max-model-len 8192, **text-only** `--limit-mm-per-prompt '{"image":0}'`,
  `--reasoning-parser qwen3`, `--tool-call-parser qwen3_coder`, sampling temp 1.0/top_p 0.95/top_k 20.
  Winner adds `--speculative-config '{"method":"qwen3_5_mtp","num_speculative_tokens":1}'`.

## Results — all three gates

| config | works (smoke) | gsm8k (good) | mmlu | mmlu_pro | chat c1 | chat c16 (fast) | c32 |
|---|---|---|---|---|---|---|---|
| baseline (no MTP) | 4/4 | 98.0 | 84.26 | 71.64 | 12.1 | 122.6 | 192.3 |
| **mtp-n1 (FINAL)** | 4/4 | **98.0** (lossless) | — | — | **16.8** | **161.5** | — |

- **Gate 1 works:** smoke 4/4. (Baseline first ran 3/4 — `hermes` parser FAILED the tool-call check;
  Qwen3.6 emits `<function=...><parameter=...>` XML, not hermes JSON → switched to **`qwen3_coder`** → PASS.)
- **Gate 2 good:** baseline mmlu (LL, think-on) **84.26**, gsm8k (think-off) **98.0**, mmlu_pro (think-off)
  **71.64** — excellent (top-tier vs the leaderboard). mtp-n1 gsm8k (think-off) **98.0 = lossless**.
- **Gate 3 fast:** mtp-n1 N=3 median chat **c16 161.5 (+31.7%)**, **c1 16.8 (+39.2%)** vs baseline —
  the **biggest MTP lift in the project** (vs Qwen3-Next +12-15%, Nemotron +14.9%). Forum reported 85-94%
  MTP acceptance single-node on this exact model; the high acceptance explains the large lift.

## Notes / lessons
- **qwen3_5_mtp on NVFP4 "just works" on stock 0.23.0** — no patched image, no checkpoint `mtp.*`
  quant-ignore patch, no `gate_up_proj`/`mtp.fc` shape fix. The qwen3_next NVFP4-MTP saga does NOT
  recur here (different loader `qwen3_5_mtp.py` + compressed-tensors handles `mtp.fc` correctly).
  → the promoted launcher is **portable** (upstream digest), unlike the Qwen3-Next finals.
- **Tool parser = `qwen3_coder`** for Qwen3.6 (the `<function=>` XML format), NOT hermes. gen_baseline's
  default guess was hermes; smoke caught it.
- **Hybrid reasoning** (`enable_thinking` toggle works) → standard suite think-off path applies; no
  always-on-reasoner handling needed. **GOTCHA:** the MTP quality gate MUST serve with `AHL_THINK_OFF=1`
  (a plain serve leaves thinking ON → `<think>` CoT overruns the 1024-tok gsm8k budget → 0.0). First
  lossless run scored 0.0 from this; re-run with AHL_THINK_OFF=1 → 98.0.
- **MTP ⊥ loglikelihood** — mtp config quality gate uses generative gsm8k (not loglikelihood mmlu).
- Dense 27B NVFP4 is bandwidth-bound: modest absolute tok/s (c16 122→161). Full both-shape characterization
  sweep on the winner skipped (promoted on gates passed); baseline full chat+coder sweep is in results.tsv.
