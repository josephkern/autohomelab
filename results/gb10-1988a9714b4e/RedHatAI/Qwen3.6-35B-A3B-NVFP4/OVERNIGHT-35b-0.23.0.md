# 35B tune queue — vLLM 0.23.0, Qwen3.6-35B-A3B-NVFP4 (2026-06-14T12:37:52Z)

Baseline (0.23.0, flashinfer_cutlass MoE + fp8 KV + MTP n=1) median **c16 = 344.62** tok/s
(N=3). Keep threshold: c16 > +3%. Quality ref: mmlu=78.19 (LIMIT=100); numeric-risky
knobs must stay within ~1%.

| candidate | c16 | c1 | status | verdict |
|---|---|---|---|---|
| moe-auto | 342.43 | 56.44 | ok | discard (within noise: -0.6%); mmlu=78.44 (0.3% vs ref 78.19) |
| moe-marlin | na | na | serve_fail | discard (serve_fail) |
| mtp-off | 294.61 | 43.97 | ok | discard (within noise: -14.5%) |
| mtp-n2 | 354.25 | 56.4 | ok | discard (within noise: +2.8%) |
| memutil-08 | 336.28 | 55.83 | ok | discard (within noise: -2.4%) |
| batched-32k-util08 | 344.04 | 56.42 | ok | discard (within noise: -0.2%) |

Recommendation: promote the best KEEP that also passes quality (if numeric-risky) via
scripts/validate.sh + scripts/promote.sh -> VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh;
else the migrated baseline stands. Independent wins can be combined into one variant + re-validated.
