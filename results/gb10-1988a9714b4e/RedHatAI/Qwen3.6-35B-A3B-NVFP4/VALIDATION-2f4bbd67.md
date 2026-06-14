# Validation report — RedHatAI/Qwen3.6-35B-A3B-NVFP4
- date: 2026-06-14T12:41:25Z
- node: gb10-1988a9714b4e   config_hash: 2f4bbd67
- runbook: runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh
- backend: vllm@unknown(img:sha256:6d8429e38e37)
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality (lm-eval general): mmlu=77.6**  (eval run: ok)
- Gate 3 throughput: see results.tsv / logbook full-sweep

Compare scores to the model card's reference (recovery %); promote only if within ~1%.
