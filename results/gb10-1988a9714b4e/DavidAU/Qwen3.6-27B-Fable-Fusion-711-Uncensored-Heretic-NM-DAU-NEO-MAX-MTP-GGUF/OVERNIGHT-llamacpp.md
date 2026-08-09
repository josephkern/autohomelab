
## llama.cpp tune queue (2026-08-09T18:28:24Z)

Baseline (same session): Q5_K_M MTP draft=2 np=16 — **c16 63.51**. KEEP rule: c16 > +3%.

| candidate | hypothesis | c16 | c1 | status | verdict |
|---|---|---|---|---|---|
| mtp-off | MTP off, matched regular Q5_K_M quant | 61.1 | 12.03 | ok | discard (-3.8% vs base) |
| mtp-d1 | MTP draft depth 1 (shallower) | 64.3 | 16.61 | ok | discard (+1.2% vs base) |
| mtp-d3 | MTP draft depth 3 (deeper) | 61.58 | 20.01 | ok | discard (-3.0% vs base) |
| q4km | Q4_K_M MTP (smaller = less bandwidth per token) | 63.37 | 20.1 | ok | discard (-0.2% vs base) |
| q6k | Q6_K MTP (larger = quality headroom, cost check) | 58.63 | 16.89 | ok | discard (-7.7% vs base) |
