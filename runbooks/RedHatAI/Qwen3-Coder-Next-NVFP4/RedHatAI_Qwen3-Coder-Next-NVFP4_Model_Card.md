# RedHatAI/Qwen3-Coder-Next-NVFP4 — model card (autohomelab)

- HF id: RedHatAI/Qwen3-Coder-Next-NVFP4
- Revision (pinned): 27a8f16f463b9a13c91c332c40cf93e09717347e
- Type: coder (non-thinking)   # drives eval suite: general→gsm8k+mmlu, coder→humaneval+mbpp
- Quantization: NVFP4 (compressed-tensors, MoE) — quant_method=compressed-tensors, status=compressed
- Native context: 262144 (max_position_embeddings; rope_theta 5e6, no rope_scaling)
- Reasoning parser: none (non-thinking; chat_template has no enable_thinking)
- Tool-call parser: qwen3_coder (XML `<tool_call><function=…><parameter=…>` format, confirmed in chat_template.jinja)
- Recommended sampling: {"top_p":0.95,"top_k":40} (generation_config.json; do_sample=true)
- Quality reference: <recovery % / published eval scores from the HF card's Evaluation section — TODO>

## Notes
- **Architecture: `Qwen3NextForCausalLM` / `qwen3_next`** — hybrid linear-attention (Gated DeltaNet)
  + sparse MoE. 48 layers, layer_types interleave 3×`linear_attention` : 1×`full_attention`
  (12 full-attention layers, full_attention_interval=4) → small KV footprint vs a dense-attn model.
  512 experts, 10 experts/tok (+ shared expert), hidden 2048, head_dim 256. ~80B-A3B class
  (45 GB NVFP4 weights on disk).
- vLLM 0.23.0 supports the arch natively (`vllm/model_executor/models/qwen3_next.py`) **and ships
  `qwen3_next_mtp.py`** → MTP multi-token-prediction speculative decoding is available; MTP was the
  dominant throughput lever on Nemotron-3-Super, so it's the top tuning candidate here.
- NVFP4 MoE: let vLLM auto-detect the moe-backend at baseline (auto≈cutlass on sm_121 per Nemotron);
  explicit `--moe-backend flashinfer_cutlass` / `marlin` are tuning candidates.
- eos is a list [151645, 151643]; bos 151643.
