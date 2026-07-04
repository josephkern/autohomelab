# 35B tune queue — vLLM 0.24.0, Qwen3.6-35B-A3B-NVFP4 (2026-07-04T22:22:55Z)

Baseline (0.24.0, flashinfer_cutlass MoE + fp8 KV + MTP n=1) median **c16 = 339.96** tok/s
(N=3). Keep threshold: c16 > +3%. Quality ref: mmlu=82.82 (LIMIT=100); numeric-risky
knobs must stay within ~1%.

| candidate | c16 | c1 | status | verdict |
|---|---|---|---|---|
| moe-auto | 339.5 | 55.44 | ok | discard (within noise: -0.1%); mmlu=81.75 (-1.3% vs ref 82.82) [QUALITY FAIL >1% drop] |
| linear-b12x | na | na | serve_fail | discard (serve_fail) |
| mtp-n2 | 360.98 | 55.72 | ok | KEEP (+6.2% c16) |
| kv-nvfp4 | na | na | serve_fail | discard (serve_fail) |

Recommendation: promote the best KEEP that also passes quality (if numeric-risky) via
scripts/validate.sh + scripts/promote.sh VLLM_TAG=24 -> VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh;
else the 0.24 baseline stands. Independent wins can be combined into one variant + re-validated.
