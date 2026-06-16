# nemotron-3-super-120B tune queue — vLLM 0.23.0 (2026-06-16T06:56:12Z)

Baseline (NVFP4 LatentMoE, auto MoE backend, gpu-mem-util 0.85, MTP off) median **c16 = 75.54**
tok/s (N=3, re-measured this session). Keep threshold c16 > +3%. Quality (mmlu loglikelihood,
think-on) ref = 85.82; numeric-risky winners must stay >-2%.

| candidate | c16 | c1 | status | verdict |
|---|---|---|---|---|
| mtp-n1 | 92.77 | 22.75 | ok | KEEP (+22.8% c16) |
| moe-b12x | na | na | serve_fail | discard (serve_fail) |
| async-sched | 76.93 | 17.65 | ok | discard (+1.8%, within noise) |
| memutil-090 | 73.54 | 17.72 | ok | discard (-2.6%, within noise) |
| moe-cutlass | 80.7 | 17.62 | ok | KEEP (+6.8% c16); mmlu=85.82 (+0.0% vs 85.82) |
| maxseqs-4 | 39.38 | 17.57 | ok | discard (-47.9%, within noise) |

Recommendation: promote the best KEEP that passes quality via FULL=1 scripts/suite.sh +
scripts/promote.sh VLLM_TAG=23 -> VLLM-23-RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B_NVFP4_final.sh;
else baseline stands. (mtp/async/memutil/maxseqs are config-only -> no quality eval; maxseqs-4 is
a per-stream characterization expected to lose the c16 objective.)
