# Wave 1 (MTP depth) — unsloth/Qwen3.8-27B-NVFP4 @ vLLM 0.27.1

Started: 2026-08-18T12:56:39Z · N=3 · shape=chat(512/256) · levels=1,16
Reference: baseline chat c16 **136.36** (same session). KEEP if >3% (>140.5).
Context: promoted Inferact final = 171.12 chat c16, on the heavier checkpoint.

| candidate | c16 med | c1 med | status | note |
|---|---|---|---|---|
| `20260818_mtp-n2_tuned.sh` | 188.34 | 23.15 | ok | MTP n=2 |
| `20260818_mtp-n3_tuned.sh` | 208.86 | 25.64 | ok | MTP n=3 (Inferact's optimum) |
| `20260818_mtp-n4_tuned.sh` | 449358.18 | 28.99 | crash | MTP n=4 |

Finished: 2026-08-18T14:05:00Z

Verdicts are NOT auto-applied. If the winner is at an edge (n=2 or n=4), extend the bracket.
