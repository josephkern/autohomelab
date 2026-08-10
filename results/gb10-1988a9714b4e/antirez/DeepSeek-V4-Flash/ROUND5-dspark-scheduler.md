
## DS4 round 5 — DSpark adaptive scheduler (2026-08-10T04:22:06Z)

Engine `ds4@84cc882`, DSpark on (conf 0.7 default).
Same-session DSpark-default base c1 **20.98**. Objective c1, N=3 median, greedy. KEEP > +3%.
Motivation: baseline stats showed `scheduler_skips=89/152 cycles (59%)`, `no_draft=112`,
yet `accept_rate=72.84%` when it does draft.

| candidate | hypothesis | c1 | status | verdict | DSpark stats |
|---|---|---|---|---|---|
| sched-off | scheduler OFF (always draft) | 21.36 | ok | discard (+1.8%) | `cycles=3754 accept_rate=88.31% avg_accept=1.965 no_draft=697 scheduler_skips=0 ` |
| sched-skip0 | SCHEDULER_SKIP 2->0 (no cooldown after a miss) | 21.48 | ok | discard (+2.4%) | `cycles=4927 accept_rate=91.16% avg_accept=1.092 no_draft=2729 scheduler_skips=2111 ` |
| sched-nodraft0 | NO_DRAFT_SKIP 3->0 | 21.39 | ok | discard (+2.0%) | `cycles=4260 accept_rate=88.62% avg_accept=1.435 no_draft=1701 scheduler_skips=992 ` |
| sched-window1 | SCHEDULER_WINDOW 4->1 | 21.49 | ok | discard (+2.4%) | `cycles=5012 accept_rate=89.50% avg_accept=1.033 no_draft=2965 scheduler_skips=2508 ` |
