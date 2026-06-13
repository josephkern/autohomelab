# Overnight queue — vLLM 0.23.0, Qwen3-8B-NVFP4 (2026-06-13T21:47:09Z)

Baseline (0.23.0 native-FP4) median c16 = **507.14** tok/s (N=3). Keep threshold: >3%.

| candidate | c16 | status | verdict |
|---|---|---|---|
| batched-16k | 504.01 | ok | discard (within noise) |
| b12x | na | serve_fail | discard (serve_fail) |
| kvfp8 | 566.49 | ok | KEEP (+11.7%); eval:gsm8k=92.0;mmlu=73.25 |
| memutil-08 | 502.84 | ok | discard (within noise) |
| batched-32k-util08 | 499.25 | crash | discard (crash) |

Recommendation: promote the best KEEP (if any) via scripts/validate.sh + scripts/promote.sh;
else the current VLLM-23 _final stands. fp8-KV verdict includes a quality eval if it survived.
