# RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 — model card (autohomelab)

- HF id: RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
- Revision (pinned): b2b9a6150f0d1d450d68b40993e4699b0cfbbab0   # main; has the 17 safetensors shards + inline quant config
- Type: reasoning (general eval tasks: gsm8k + mmlu + mmlu_pro; thinking-OFF generative path auto-applied)
- Architecture: NemotronHForCausalLM — hybrid Mamba-Transformer ("Nemotron-H") + **LatentMoE** (tokens
  projected to a smaller latent dim for expert routing), 88 layers, 22 experts/tok, 2 KV-heads. Has native
  **MTP** (Multi-Token Prediction) layers → native speculative decoding (a tune candidate).
- Quantization: ModelOpt, `quant_algo=MIXED_PRECISION` — majority linear layers NVFP4 (W4A4); latent
  projections, MTP layers, QKV/attention, embeddings kept BF16/MXFP8. KV scheme baked in as **FP8** (8-bit float).
- Native context: 262144 (256K). Benchmark runbook uses --max-model-len 8192; raise for long-context runs
  (KV is the binding constraint at 256K: ~22 GB/full-seq → concurrency-limited, see kv_calc).
- Reasoning parser: **nemotron_v3** (built into vLLM 0.23.0 as NemotronV3ReasoningParser ⊂ DeepSeek-R1
  `<think>` parsing — VERIFIED registered; the README's "download super_v3 plugin" step is for older vLLM
  ≤0.18 without the built-in). Reasoning ON is the default; configurable via chat-template `enable_thinking`
  → our thinking-OFF generative eval path uses `enable_thinking=false`.
- Tool-call parser: **qwen3_coder** (+ --enable-auto-tool-choice)
- Recommended sampling: {"temperature":1.0,"top_p":0.95}   # README: use across ALL tasks/backends
- Quality reference (NVFP4 column, NVIDIA's published Nemo-Evaluator scores):
  MMLU-Pro **83.33** · GPQA (no tools) **79.42** · MMLU-ProX (multiling avg) **79.37**.
  (FP8/BF16 columns within ~0.5 pt — NVFP4 recovery is essentially lossless on these.)

## Notes
- Validated_on per the HF card: vLLM 0.18.0 (RHOAI/RHAIIS 3.4). We run **0.23.0** (newer; registers the
  arch + nemotron_v3 natively). Onboarding image = lab default 0.23.0.
- Functional flags confirmed against this card: nemotron_v3 reasoning, qwen3_coder tools, temp1.0/top_p0.95.
- gpu-memory-utilization 0.85 is model-DRIVEN here (weights ~74.8 GB = 0.62 of the 121.6 GiB unified pool;
  the generic 0.50 unified default cannot load it). See baseline.sh header.
- Tune candidates (Fig-4 slider, blog 2026-06-01): FP4 --moe-backend/--linear-backend, validated FP8 KV,
  async scheduling, MTP --speculative-config, gpu-mem-util ceiling, blog's --max-num-seqs 4 (latency).
</content>
