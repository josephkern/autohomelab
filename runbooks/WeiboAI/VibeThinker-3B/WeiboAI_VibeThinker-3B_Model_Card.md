# WeiboAI/VibeThinker-3B — model card (autohomelab)

- HF id: WeiboAI/VibeThinker-3B
- Revision (pinned): 0c7115fdd0957b3da0f2a0829ab1763969d30300   # the CACHED rev (local weights); HF main moved to 51e5928
- Type: reasoning (competition-math). **Quality gate = `math` suite** (aime24,aime25), NOT general/coder.
- Architecture: Qwen2ForCausalLM (Qwen2.5-3B base, fine-tuned from Qwen2.5-Coder-3B). DENSE, 36 layers,
  hidden 2048, GQA. Native ctx 131072 (paper: trained on a single 64K window), sliding_window 32768.
- Quantization: NONE (BF16, 5.8 GB) — tiny, loads in ~2 min (JIT warmup), fits trivially on the unified pool.
- Reasoning parser: **none** in the baseline (kept parser-less for eval robustness) — BUT note the model DOES
  emit DeepSeek-R1-style `<think>…</think>` then the answer (verified; closes the tag reliably). `--reasoning-
  parser deepseek_r1` would split it cleanly for serving (optional config; risks empty `content` if a hard
  problem's reasoning never closes `</think>` within budget — the Nemotron trap). Eval reads full `content`
  (boxed answer survives regardless).
- Tool-call parser: none (not agentic).
- Recommended sampling: **temp 1.0, top_p 0.95, top_k -1** (paper + card; "all tasks"). generation_config.json
  has NO sampling fields → set via --override-generation-config in the runbook. RL-tuned for sampling; greedy
  risks repetition loops → eval the math gate at temp 1.0 (GEN_KWARGS do_sample=True), not greedy.
- Quality reference (paper 2606.16140, Pass@1): **AIME26 94.3, HMMT25 89.3, BruMO25 93.8, LiveCodeBench v6
  80.2, IFEval 93.4** (matches 671B–1T models on contest math). With CLR test-time scaling: AIME26 97.1.
  (We measure aime24/aime25 — same benchmark family, different years than the paper's AIME26.)

## Notes
- "A bit different": a **long-CoT** model — recommends `max_new_tokens=102400`. Generations run many minutes
  (32K tokens @ ~tens of tok/s, slower under concurrency). This breaks stock eval defaults; the `math` suite
  handles it: GEN_TOKS auto-32768 + `EVAL_TIMEOUT=1800` (lm-eval's 300s default times out).
- **MATH-500 extraction gotcha:** `minerva_math500` ("Final Answer: … I hope it is correct" regex) and
  `hendrycks_math500` (`$…$`) do NOT extract `\boxed{}` → score ~0 (format mismatch, not failure). The `aime`
  tasks PREFER `\boxed{}` (last_boxed_only_string) → correct. Hence the gate is aime24,aime25.
- Eval runs via the CHAT endpoint (`THINK=off` → apply_chat_template; it's chat-tuned, nothing to "disable").
- max-model-len 40960 in the runbook: large to fit the math eval's long CoT; throughput shapes unaffected.
</content>
