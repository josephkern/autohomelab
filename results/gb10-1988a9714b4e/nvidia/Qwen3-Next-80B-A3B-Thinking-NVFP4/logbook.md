# nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 — logbook (GB10 node #1)

**STATUS: COMPLETE — promoted `VLLM-23-nvidia_Qwen3-Next-80B-A3B-Thinking_NVFP4_final.sh`** (winner =
mtp-n1, native qwen3_next MTP num_spec=1). 2026-06-23. Branch `autoresearch/qwen3-next-80b-thinking`.

Direct Thinking analog of the completed Instruct-NVFP4 campaign — same arch, NVFP4 path, patched MTP
image, and tuning lever all carried over cleanly. MTP is again the dominant (and only needed) lever.

## Environment (AGENTS rule #3)
- node_fp: `gb10-1988a9714b4e` — NVIDIA GB10, sm_121, aarch64, ~121.6 GiB unified LPDDR5X
- driver 580.159.03, CUDA 13.0
- backend: vLLM **0.23.0**, patched image `vllm-openai:0.23.0-qwen3nextmtp-fix` (local id sha256:628a16cc,
  base `vllm/vllm-openai@sha256:6d8429e3`), torch 2.11.0+cu130. GuideLLM 0.6.0.
- model: `nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4` rev `2adcdd3e2482cd6fa1676b4f8e6f459a28796f08`
  (NVFP4 ModelOpt, ~50.8 GB, `Qwen3NextForCausalLM`, native MTP head). Checkpoint patched (`mtp.*`
  added to quant-ignore via scripts/patch_qwen3next_mtp_ignore.py) so mtp.fc stays bf16.
- serve flags: TP1, gpu-mem-util 0.5, max-model-len 8192, reasoning-parser qwen3, tool-call-parser
  hermes, sampling temp 0.6/top_p 0.95/top_k 20. Winner adds `--speculative-config
  '{"method":"qwen3_next_mtp","num_speculative_tokens":1}'`.

## Results — all three gates

| config | works (smoke) | gsm8k flex (good) | chat c1 | chat c16 (fast) | chat c32 | coder c16 |
|---|---|---|---|---|---|---|
| baseline (no MTP) | PASS | 81 | 42.3 | 256.85 | 361.92 | 219.15 |
| **mtp-n1 (FINAL)** | PASS | **81** (lossless) | **56.23** | **295.14** | — | — |

- **Gate 1 works:** smoke PASS on both baseline + mtp-n1.
- **Gate 2 good:** baseline mmlu (loglikelihood, think-on) = **84.32** (≈ Instruct's 84.88 → NVFP4 quality
  intact). gsm8k generative (flexible) **81 → 81** = MTP greedy-lossless. (strict-match is a format
  artifact for an always-on reasoner: 25/32, meaningless; flexible is the signal.)
- **Gate 3 fast:** mtp-n1 N=3 median chat **c16=295.14 (+14.9%)**, **c1=56.23 (+33.0%)** vs baseline —
  matches the Instruct sibling (+12.4% / +30%). 3 benches tight: 295.14/293.2/296.07.
- Promote skipped the full both-shape characterization sweep (user call) — gates passed on N=3 c1/c16
  + lossless gsm8k. Baseline full sweep is recorded (chat + coder rows in results.tsv).

## Model-specific notes / lessons
- **Always-on reasoner — no `enable_thinking` switch.** chat_template.jinja line 85 unconditionally
  opens `<think>` (unlike hybrid Qwen3 8B/35B). So the suite's auto think-OFF generative path is
  **inert** here (the `enable_thinking=false` kwarg is ignored; the model still emits `<think>`).
- **Eval recipe (the VibeThinker long-CoT path):** generative gates run on the **chat endpoint**
  (`THINK=off` = apply_chat_template; enable_thinking inert but harmless), `TASKS=gsm8k` (so mmlu's
  loglikelihood doesn't abort the chat-endpoint call), **`GEN_TOKS` capped under the 8192 serve
  ceiling** (32768 → every request 400s `max_tokens > max_model_len`; 4096 works). gsm8k ran greedy
  (lm-eval's task default temp 0; did NOT loop) → clean lossless comparison; 100 Q in ~8 min.
- **mmlu_pro generative is INTRACTABLE here** — long-CoT × 14 categories DNF past 75 min even at
  LIMIT=50/GEN_TOKS=4096. Use loglikelihood mmlu (84.32) for the absolute reference + gsm8k flexible
  for the generative/MTP gate. (FOLLOW-UP: suite.sh should detect always-on reasoners — clamp
  generative GEN_TOKS to the serve max-model-len and skip/limit mmlu_pro — rather than relying on
  caller overrides.)
- **MTP ⊥ loglikelihood** (NaN prompt_logprobs) — the mtp config's quality gate MUST be generative.
- Upstream: vLLM PR #46316 (from our #35031 writeup) is the in-code fix for patches #1+#2; on the
  same GB10 @WindChimeRan loaded MTP clean from that branch WITHOUT patch #3 (pynvml) — patch #3 may
  be 0.23.0-image/dep-specific, not a permanent Spark requirement. Revisit when #46316 ships.
