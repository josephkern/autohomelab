
## DS4 round 4 — DSpark re-test (2026-08-09T20:14:16Z)

Engine `ds4@84cc882`; target-only base c1 **19.27** (same session).
Objective c1, N=3 median, greedy. KEEP rule: c1 > +3%.

| candidate | hypothesis | c1 | status | verdict |
|---|---|---|---|---|
| dspark-default | DSpark @ CUDA default confidence 0.7 | 20.61 | ok | KEEP (+7.0%) — NEEDS ITS OWN GATE 2 (DSpark is not greedy-lossless) |
| dspark-c05 | DSpark confidence 0.5 (admit more drafts) | 21.56 | ok | KEEP (+11.9%) — NEEDS ITS OWN GATE 2 (DSpark is not greedy-lossless) |
| dspark-c085 | DSpark confidence 0.85 (prune harder) | 20.5 | ok | KEEP (+6.4%) — NEEDS ITS OWN GATE 2 (DSpark is not greedy-lossless) |
| dspark-strict | DSpark loaded, target-only decode (control) | 19.3 | ok | discard (+0.2%) |

## DS4 round 4 — DSpark re-test (2026-08-09T20:36:10Z)

Engine `ds4@84cc882`; target-only base c1 **19.27** (same session).
Objective c1, N=3 median, greedy. KEEP rule: c1 > +3%.

| candidate | hypothesis | c1 | status | verdict |
|---|---|---|---|---|
| dspark-c03 | DSpark confidence 0.3 (admit still more) | 20.52 | ok | KEEP (+6.5%) — NEEDS ITS OWN GATE 2 (DSpark is not greedy-lossless) |
| dspark-c00 | DSpark confidence 0 (fixed 5-token blocks) | 20.5 | ok | KEEP (+6.4%) — NEEDS ITS OWN GATE 2 (DSpark is not greedy-lossless) |
