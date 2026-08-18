# Wave 2 — unsloth/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1

Started: 2026-08-18T19:25:16Z · N=3 · shape=chat(512/256) · levels=1,16
Reference: MTP n=3 chat c16 **208.86**. KEEP if >3% (>215.1).

| candidate | c16 med | c1 med | status | note |
|---|---|---|---|---|
| `20260818_n3-schedtok8k_tuned.sh` | na | na | serve_fail | --max-num-scheduled-tokens 8192 (the untested Inferact thread) |
| `20260818_n3-qwen35mtp_tuned.sh` | 206.94 | 25.8 | ok | arch-specific spec method qwen3_5_mtp vs generic mtp |
| `20260818_n3-dspark-n7_tuned.sh` | na | na | serve_fail | DSpark drafter n=7 (NUMERIC-RISKY: needs its own Gate 2) |

Finished: 2026-08-18T19:55:35Z

Verdicts NOT auto-applied. A crashed row writes a BOGUS tok/s (few requests returning
instantly against a dead endpoint inflate successful.mean) — always check status before
reading a number, and mark crashed rows status=crash / tps_c16=na.
