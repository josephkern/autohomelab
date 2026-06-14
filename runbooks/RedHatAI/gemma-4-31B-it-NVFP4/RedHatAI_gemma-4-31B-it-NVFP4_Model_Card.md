# RedHatAI/gemma-4-31B-it-NVFP4 — model card (autohomelab)

- HF id: RedHatAI/gemma-4-31B-it-NVFP4
- Revision (pinned): c4905986988f1406d7d7d80200d81099977a9123
- Type: general (instruction-tuned; supports thinking/reasoning + function calling) → eval suite: general (gsm8k+mmlu)
- Quantization: NVFP4 (nvfp4-pack-quantized / compressed-tensors, W4A4) — auto-detected, no --quantization flag
- Architecture: DENSE (Gemma4ForConditionalGeneration, multimodal — served TEXT-ONLY). NOT MoE.
  60 layers, hybrid attention (sliding-window 1024 + full every 6th layer), head_dim 256,
  16 kv-heads/32 heads, final_logit_softcapping 30.0, tied embeddings, vocab 262144.
- Native context: 262144 (256K). Baseline capped at 8192 for the chat benchmark shape.
- Reasoning parser: gemma4 (HF card; thinking mode)
- Tool-call parser: gemma4 + --enable-auto-tool-choice (HF card; function calling)
- Multimodal: --limit-mm-per-prompt image=0 to skip the vision encoder for text-only serving (card tip)
- Recommended sampling: {"temperature":1.0,"top_p":0.95,"top_k":64} (generation_config.json)
- Quality reference (HF card Evaluation, vs google/gemma-4-31B-it BF16, **thinking OFF**):
  | benchmark | BF16 | NVFP4 | recovery |
  |---|---|---|---|
  | GSM8k-Platinum (5-shot, strict) | 97.60 | 97.71 | 100.1% |
  | MMLU-CoT (5-shot, strict) | 90.53 | 90.06 | 99.5% |
  | MMLU-Pro (5-shot, custom-extract) | 85.03 | 84.07 | 98.9% |
  | IFEval (0-shot, prompt-level strict) | 91.07 | 90.45 | 99.3% |

## Notes
- The card's eval numbers use MMLU-CoT / MMLU-Pro with **thinking turned off**; our in-loop
  `eval.sh general` runs *standard* mmlu (loglikelihood, unaffected by sampling) + gsm8k. Treat our
  own baseline mmlu as the internal tuning reference (matched-LIMIT recovery), not a 1:1 vs the card.
  The `resistant` suite (mmlu_pro, gpqa_diamond) would map closer to the card if needed.
- Known eval caveat (repo-wide): the baked `--override-generation-config` chat sampling bleeds into
  lm-eval generative tasks; thinking mode adds CoT traces too → trust mmlu over gsm8k here.
- Dense NVFP4 on sm_121: expect the dense native-FP4 kernel path (like Qwen3-8B), no MoE backend knob.
