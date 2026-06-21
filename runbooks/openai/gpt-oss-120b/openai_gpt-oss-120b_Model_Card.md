# openai/gpt-oss-120b — model card (autohomelab)

- HF id: openai/gpt-oss-120b
- Revision (pinned): b5c939de8f754692c1647ca79fbf85e8c1e70f8a
- Type: reasoning (general-purpose + agentic/coding flagship)  # eval: general→gsm8k+mmlu, +resistant mmlu_pro
- Arch: `GptOssForCausalLM` / `gpt_oss` — sparse MoE, 36 layers, 128 experts / **4 per tok**,
  117B total / **5.1B active**, alternating sliding(128)/full attention, head_dim 64, 8 KV heads.
- Quantization: **MXFP4** (`quant_method=mxfp4` → vLLM `gpt_oss_mxfp4`). Only the **MoE experts** are
  MXFP4; `self_attn`, `mlp.router`, `embed_tokens`, `lm_head` stay BF16 (`modules_to_not_convert`).
  ~61 GB on disk. **OpenAI ran all published evals at this same MXFP4** → our scores compare directly.
- Native context: 131072 (yarn rope, factor 32 over base 4096). Baseline serves `--max-model-len 8192`.
- Reasoning parser: **openai_gptoss** (native Harmony channel parsing; vLLM auto-sets it). Reasoning
  effort is **configurable low/medium/high** via the system prompt ("Reasoning: high") / chat-template
  kwarg `reasoning_effort` — NOT an on/off `enable_thinking` switch. For the generative think-off eval
  serve use `AHL_THINK_OFF_KWARGS='{"reasoning_effort": "low"}'` (PROBE `content` non-empty first —
  Harmony routes the final answer to `content` and CoT to `reasoning_content`).
- Tool-call parser: **openai** (registered name; `gptoss_tool_parser`). `--enable-auto-tool-choice`.
- Recommended sampling: temp 1.0 / top_p 1.0 (gpt-oss default; `generation_config.json` has only
  `do_sample=true`, no explicit temp → no `--override-generation-config`). Eval pins greedy.
- Quality reference (HF card / OpenAI, MXFP4): strong on MMLU, GPQA, AIME, codeforces; exact numbers
  in the card's Evaluation section — record measured gsm8k/mmlu/mmlu_pro vs these at baseline.

## Notes
- **NOT an MTP/qwen3_next run** — MXFP4, no MTP head. The qwen3-next MTP infra does not apply. This is
  a "characterize the GB10 flagship" campaign (the DGX-Spark daily-driver research names gpt-oss-120b
  THE real-world coding-agent flagship; commonly served via SGLang in the wild — we test vLLM).
- **sm_121 serve risk (pre-flight gate):** the Aug-2025 launch needed a special `vllm==0.10.1+gptoss`
  wheel. By the pinned **0.23.0** gpt-oss is mainline: `GptOssForCausalLM` registered, `gpt_oss_mxfp4`
  quant present, and the MXFP4 MoE backend oracle has Triton + **Marlin** fallbacks (min cap 80, so
  Blackwell sm_121 qualifies; Marlin is the path already validated here for NVFP4). Confirm live which
  backend is selected in the serve log.
- vLLM auto-bumps max cudagraph capture size to 1024 for gpt-oss (perf); leave default.
