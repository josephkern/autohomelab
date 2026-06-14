# Validation report — RedHatAI/Qwen3-8B-NVFP4 (vLLM 0.23.0, native FP4 + fp8 KV)
- date: 2026-06-14T08:26:19Z   node: gb10-1988a9714b4e   config_hash: 68acc088
- runbook: 20260613_kvfp8_tuned.sh (native NVFP4 W4A4 + --kv-cache-dtype fp8_e4m3 + --reasoning-parser qwen3)
- backend: vllm@0.23.0 (img 6d8429e)
- **Gate 1 functional (smoke): PASS 3/3**
- **Gate 2 quality (RELATIVE, matched LIMIT=100):** gsm8k=92.0 mmlu=73.25 vs 0.23.0-native 91.0/73.61
  -> mmlu -0.36 (99.5% recovery), gsm8k +1 -> PASS. Full-eval absolute (for record): gsm8k=87.64 mmlu=70.99.
  NOTE: recovery requires MATCHED eval settings; full vs LIMIT are not comparable.
- **Gate 3 throughput:** c1=41.9 c4=164.3 c8=309.3 c16=563.2 c32=950.6 vs 0.23.0-native 507/770.8
  -> c16 +11%, c32 +23%.
