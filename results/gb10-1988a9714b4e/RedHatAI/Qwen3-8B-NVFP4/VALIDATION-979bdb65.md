# Validation report — RedHatAI/Qwen3-8B-NVFP4 (vLLM 0.23.0)
- date: 2026-06-13T18:38:21Z
- node: gb10-1988a9714b4e   config_hash: 979bdb65
- runbook: runbooks/RedHatAI/Qwen3-8B-NVFP4/baseline.sh (native NVFP4 W4A4 + functional flags)
- backend: vllm@0.23.0 (img:sha256:6d8429e38e37)
- **Gate 1 functional (smoke): PASS 3/3** — chat, structured JSON, reasoning-parser routing (no <think> leak)
- **Gate 2 quality (lm-eval general, LIMIT=100): gsm8k=91.0 mmlu=73.61** — vs 0.22.0 ref gsm8k=87.0 mmlu=73.49 → within noise, no regression
- **Gate 3 throughput (chat, 180s): c1=40.6 c4=155.0 c8=285.7 c16=497.0 c32=770.8** — vs 0.22.0 c16=486.7/c32=745.7 → +2.1%/+3.4%
- functional: --reasoning-parser qwen3, sampling temp0.6/top_p0.95/top_k20
