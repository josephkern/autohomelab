# gemma-4-31B tune queue — vLLM 0.23.0 (2026-06-15T01:40:07Z)

Baseline (dense NVFP4, auto cutlass GEMM, kv auto) median **c16 = 104.31** tok/s (N=3).
Keep threshold c16 > +3%. Quality (gsm8k) ref = 73.0; numeric-risky winners must stay >-2%.

| candidate | c16 | c1 | status | verdict |
|---|---|---|---|---|
| kvfp8 | 129.16 | 10.62 | ok | KEEP (+23.8% c16); gsm8k=68.0 (-6.8% vs 73.0) [QUALITY FAIL >2% drop] |
| memutil-08 | 105.22 | 10.45 | ok | discard (+0.9%, within noise) |
| batched-16k | 103.04 | 10.54 | ok | discard (-1.2%, within noise) |
| linear-marlin | 84.59 | 10.47 | ok | discard (-18.9%, within noise) |
| linear-b12x | na | na | serve_fail | discard (serve_fail) |

Recommendation: promote the best KEEP that passes quality via FULL=1 scripts/suite.sh +
scripts/promote.sh VLLM_TAG=23 -> VLLM-23-RedHatAI_gemma-4-31B-it_NVFP4_final.sh; else baseline stands.
