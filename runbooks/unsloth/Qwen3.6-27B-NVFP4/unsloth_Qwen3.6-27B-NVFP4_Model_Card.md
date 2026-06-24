# unsloth/Qwen3.6-27B-NVFP4 — model card (autohomelab)

- HF id: unsloth/Qwen3.6-27B-NVFP4
- Revision (pinned): 890bdef7a42feba6d83b6e17a03315c694112f2a
- Base: Qwen/Qwen3.6-27B (faithful quant; unsloth is a reputable publisher). Type: **reasoning**
  (hybrid thinking, multimodal).   # eval: general→gsm8k+mmlu, +resistant mmlu_pro
- Arch: **`Qwen3_5ForConditionalGeneration`** / `qwen3_5` — **multimodal (vision)**, text backbone
  `qwen3_5_text`. **DENSE** 27B (no experts), 64 layers, vision tower depth 27.
- **MTP: PRESENT + preserved in this build** — `text_config.mtp_num_hidden_layers=1` (1 nextn layer;
  dense≠no-MTP). vLLM 0.23.0 supports it natively (`qwen3_5_mtp.py`, method `"qwen3_5_mtp"`; upstream
  fixes #35675/#39475 merged). Lever → `--speculative-config '{"method":"qwen3_5_mtp","num_speculative_tokens":1}'`
  (1 layer → num_spec=1). DGX-Spark forum: MTP **85-94% acceptance single-node** (the dual-node
  allgather-overhead caveat is N/A for our TP1).
- Quantization: **NVFP4 (compressed-tensors W4A4)**, ~26.4 GB on disk. Auto-detected (no `--quantization`);
  expect Marlin/cutlass FP4 kernels on sm_121 as with our other NVFP4 models. gpu-mem-util **0.5** ample.
- Native context: 262144. Baseline serves `--max-model-len 8192` (benchmark shape).
- Reasoning parser: **qwen3** — HYBRID: `<think>` CoT + `enable_thinking` toggle (chat_template L149:
  `enable_thinking is false → <think>\n\n</think>`). The suite's standard think-OFF generative path
  WORKS here (unlike the always-on Qwen3-Next-Thinking) — normal gsm8k/mmlu_pro eval.
- Tool-call parser: **hermes** (15 tool refs in chat_template).
- Recommended sampling: temp **1.0** / top_p 0.95 / top_k 20 (`generation_config.json`). Eval pins greedy.
- Quality reference: fill from the Qwen3.6 release/HF card; record measured gsm8k/mmlu/mmlu_pro at baseline.

## Notes
- **Serve TEXT-ONLY** via `--limit-mm-per-prompt '{"image":0}'` (matches our text benchmark/eval; vision
  eval is a separate opt-in). Closest prior analog = gemma-4-31B-it (dense multimodal, text-only).
- **Campaign = MTP tune** (like Qwen3-Next): baseline (no MTP) → mtp-n1 (qwen3_5_mtp num_spec=1).
  Bandwidth-bound on GB10 → modest absolute tok/s (NVFP4 ~26 GB read/token is far better than BF16's
  55 GB; forum dual-node saw 7.8-20.9 tok/s gen). MTP is the primary lever; secondary = kv-cache-dtype
  fp8, attention backend, gpu-mem-util.
- **NVFP4 + MTP loading is LESS proven than FP8 + MTP.** This build preserves the MTP weights, but if
  vLLM's qwen3_5_mtp loader hits an mtp.fc quant/shape issue (cf. the qwen3_next NVFP4 saga: gate_up_proj
  mapping, mtp.fc in the quant-ignore glob), apply the analogous playbook (checkpoint quant-ignore patch
  and/or qwen3_5_mtp.py fix). The non-MTP baseline should serve clean on the stock 0.23.0 image.
- Alternatives if NVFP4+MTP won't load: `Qwen/Qwen3.6-27B-FP8` (official, 30.9 GB, MTP intact,
  forum-validated) or `RedHatAI/Qwen3.6-27B-FP8`.
- **mmlu loglikelihood caveat** (AGENTS.md): cross-check with generative gsm8k + mmlu_pro before trusting.
