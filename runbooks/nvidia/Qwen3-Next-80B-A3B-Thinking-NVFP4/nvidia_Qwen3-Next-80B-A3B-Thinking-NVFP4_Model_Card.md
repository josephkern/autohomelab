# nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 — model card (autohomelab)

- HF id: nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4
- Revision (pinned): 2adcdd3e2482cd6fa1676b4f8e6f459a28796f08
- Type: **reasoning** (always-on long-CoT)   # eval: general→gsm8k+mmlu, +resistant mmlu_pro
- Arch: `Qwen3NextForCausalLM` / `qwen3_next` — sparse MoE A3B (80B total / ~3B active), hybrid
  (gated-DeltaNet linear attn + sparse full attn). **Native MTP head present** (`mtp.layers.0*` in
  the NVFP4 ignore-list, same as the Instruct NVFP4) → the qwen3_next_mtp spec-decode lever applies.
- Quantization: **NVFP4** (ModelOpt; `quant_method=modelopt`). ~50.8 GB on disk.
- Native context: 262144 (check config; baseline serves `--max-model-len 8192`).
- Reasoning parser: **qwen3** — the chat_template **ALWAYS** opens `<think>` at the assistant turn
  (chat_template.jinja line 85: `<|im_start|>assistant\n<think>\n`) and there is **NO `enable_thinking`
  switch**. This is a pure always-on reasoner (cf. VibeThinker), unlike the hybrid Qwen3 8B/35B which
  gate thinking. Parser routes the `<think>…</think>` CoT to `reasoning_content`, answer to `content`.
- Tool-call parser: **hermes** (JSON-in-XML; chat_template has tool support).
- Recommended sampling: temp 0.6 / top_p 0.95 / top_k 20 (`generation_config.json` — Thinking-tuned;
  differs from the Instruct build's 0.7/0.8/20). Eval pins greedy unless a long-CoT temp is needed.
- Quality reference: fill from the HF card's Evaluation section (AIME/GPQA/LiveCodeBench frontier for
  the Thinking line); record measured gsm8k/mmlu_pro vs these at baseline.

## Notes
- **Reuses the Qwen3-Next-80B-A3B-Instruct-NVFP4 campaign infra wholesale** — same arch, same NVFP4
  path, same patched MTP image (`vllm-openai:0.23.0-qwen3nextmtp-fix`, vLLM #35031 3-patch fix). The
  Instruct campaign's **mtp-n1 (num_spec=1) was the dominant lever (+12.5% c16 / +30% c1)** — primary
  candidate here. num_spec=1 fits the single nextn layer (vLLM warns num_spec>1 reuses it → lower accept).
- **Gate-2 eval caveat (IMPORTANT):** no `enable_thinking` off-switch → `AHL_THINK_OFF` is **inert**
  (the kwarg is ignored by the template; the model still emits `<think>`). Do NOT trust a "think-off"
  serve here. Run generative gsm8k/mmlu_pro **thinking-ON** with large `GEN_TOKS` (auto-32768) + long
  `EVAL_TIMEOUT` (the VibeThinker long-CoT recipe), via the chat endpoint. PROBE `content` non-empty
  (answer lands after `</think>`) before trusting scores.
- **MTP ⊥ loglikelihood:** the mtp variant returns NaN prompt_logprobs → loglikelihood `mmlu` 400s.
  Quality gate for the mtp config MUST use generative tasks (gsm8k/mmlu_pro), not loglikelihood mmlu.
- Quiesce the box; N=3 median; objective = chat c16 tok/s (AGENTS.md).
