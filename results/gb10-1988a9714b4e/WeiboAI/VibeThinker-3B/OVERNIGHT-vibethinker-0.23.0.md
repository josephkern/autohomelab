# vibethinker-3b tune queue — vLLM 0.23.0 (2026-06-17T18:35:22Z)

Baseline median **c16 = 509.81** tok/s chat (N=3). Keep threshold +3%. Throughput-only
(BF16 weights unchanged) -> no quality eval; competition-math gate (aime24=90.0/aime25=86.67) stands.

| candidate | c16 | c1 | verdict |
|---|---|---|---|
| async-sched | 510.38 | 29.57 | discard (+0.1%, within noise) |
| batched-32k | 507.6 | 29.56 | discard (-0.4%, within noise) |

Recommendation: promote best KEEP via promote.sh VLLM_TAG=23; else baseline stands (the
compute-bound 3B baseline is already well-tuned; finalize throughput = the committed full sweep).
