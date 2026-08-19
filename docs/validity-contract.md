# Measurement-validity contract (v1.2)

The binding spec for the §1 work of [issue #1](https://github.com/josephkern/autohomelab/issues/1).
v1.0 authored 2026-08-19 as the fixed interface ten parallel agents built against; **v1.1 (same
day) folds in the eleven adjudications those agents' findings forced.** Where v1.1 differs from
v1.0, v1.1 wins — the implementation matches v1.1.

## 0. Why

The project's only product is measurements. Three defects in one session each wrote
`status=measured` rows that were wrong and raised no error: a c32 figure averaged over **2**
completed requests, a `tps_c16` of **449,358** from a dead endpoint, and a spec-decode config
scored by a loglikelihood task returning `NaN` for 56,168 requests. The failure mode of this
codebase is not a crash, it is a plausible number.

**Scope limit, stated plainly:** the third defect is a **Gate 2** failure. Every rule below reads
GuideLLM level JSON, so nothing here would catch a repeat of it. This contract closes the
throughput path only. Gate 2 has no validity layer and that remains an open follow-up.

## 1. Single source of truth

`scripts/lib/validity.py` is the **only** implementation of the rules. `scripts/lib/validity.sh`
is a thin bash shim; it re-implements nothing. The header string previously existed in four
hard-coded copies (`bench.sh`, `bench_ds4.sh`, `bench_llamacpp.sh`, `aggregate.py`) — all four now
consume it from the library.

## 2. `results.tsv` schema (23 columns)

```
run_id  commit  node_fp  model  shape  backend  config_hash  script
load_s  max_s  seed  tps_c1  tps_c4  tps_c8  tps_c16  tps_c32  peak_gb
req_counts  validity  knobs  status  notes  data
```

- **`req_counts`** — per-level request outcome as **`ok/incomplete/errored`** (that order),
  semicolon-joined, run levels only: `c1:41/0/0;c16:118/4/0`. A level that ran but produced no
  parseable JSON renders `c16:na`. The whole field is `na` only when the row has no bundle
  path at all (`data=na`). **A bundle directory that survives but retains no `level_c*.json`
  is NOT the same case**: those rows render `c1:na` and score `no_data`, which is fatal and
  therefore stricter than `na`. Of the 6 unauditable rows, 1 is `data=na` and 5 are
  retained-but-empty directories, so only 1 row carries `validity=na`.
- **`validity`** — `ok`, or a `+`-joined list of verdict tokens (§3).
- **`knobs`** — effective knob set, `k=v` comma-joined:
  `levels=1|16,max_s=180,seed=42,prompt=512,output=256,stall=90,ltimeout=480,gllm=0.6.0`.

**Value encoding (v1.1).** No value may contain the pair separator. List values use `|`
(`levels=1|16`), so a naive `split(",")` is always correct. v1.0's `levels=1,16` example was not
round-trippable and is withdrawn.

**`tps_c*` sentinels.** `na` = level not run. **`hang`** = the level that wedged — an undocumented
sentinel present on 13 historical cells. Anything parsing these columns as float must handle both.

Column order is fixed. No value is ever empty (`na`), and none contains a tab or newline.

## 3. Verdict tokens

**Tokens carry the level they refer to (v1.1):** `low_sample@c1`, `no_data@c32`,
`survivorship@c16`. Only `ok` and `nonmonotonic` are row-wide and untagged. Rationale: severity was
per-row in v1.0, so a structurally-thin c1 sentinel condemned a campaign's c16 objective. Consumers
gate on the level they actually cite. It also names the wedged level on a crash row.

| token | rule | severity |
|---|---|---|
| `ok` | all checks pass | — |
| `no_data` | a run level has `successful < AHL_MIN_DATA` (**5**), or its `level_c<N>.json` is missing/unparseable | fatal |
| `low_sample` | `successful * mean_output_tokens < AHL_MIN_TOKENS` (**2048**) **OR** `successful < max(AHL_MIN_DATA, min(20, 4*level))` | suspect |
| `over_roofline` | a level's tok/s exceeds the §4 ceiling | fatal |
| `survivorship` | `incomplete >= successful` | suspect |
| `nonmonotonic` | a run level is more than **10%** below the **immediately preceding** run level | suspect |
| `errored` | `errored > 10%` of `successful + errored` | suspect |
| `na` | rules could not be evaluated (no bundle) — never `ok` | — |

**`low_sample` (v1.1).** v1.0's flat 20-request floor was miscalibrated: it fired on 55% of the
historical corpus, 160 of 181 flagged bundles offended only at c1, and at c1 the sample count is
`MAX_SECONDS / per-request latency` — arithmetic, not operator error. Measured across 77 replicate
brackets, the median CV of reported tok/s is 0.39% at n<10 and 1.42% at 10<=n<20 vs 0.56% at
20<=n<50: **request count does not predict reproducibility; tokens generated does.** The token
budget is therefore the primary clause. Measured result: 4% suspect, all §0 defects still caught.

**`survivorship` (v1.1, new).** GuideLLM's `successful.mean` silently drops incomplete requests,
which are the *slow* ones, so the reported mean is the mean of the faster half — a directional
bias that grows with concurrency (chat c1 0.1% discarded, chat c32 10.3%, coder c16 32.4%, coder
c32 46.2%). This is the mechanism behind the "non-monotonic coder curve": throughput is not
falling, the estimator stops keeping up.

**`nonmonotonic` is adjacent-only (v1.1)** — each run level against the previous run level, never
pairwise across the whole curve. This box legitimately plateaus at high concurrency; pairwise-all
would flag gentle decay as an inversion. v1.0 left this unspecified, which left the rule untested
at 3+ levels.

`no_data` and `low_sample` are mutually exclusive **per level**. A level is **run** if the journal
published a cell **or** a bundle file exists — the union. Unrun levels are skipped, never scored as
zero. A hung level is scored (and its token names it), not skipped. The run-level *list* is
authoritative over a directory listing, so a stale `level_c8.json` from a previous shape is ignored.

## 4. Physical ceiling (roofline)

With batch B, one decode step reads the weights once and emits B tokens:

```
ceiling(level) = SAFETY * level * (mem_bw_GB_s / bytes_per_token_GB)      GB = 10^9
```

- `mem_bw_GB_s` ← `node_profile.json` → `gpu.mem_bw_gbs` (273 for GB10). Absent or `null` → the
  check is **skipped**, never guessed.
- `bytes_per_token_GB` ← `AHL_MIN_MODEL_GB` (**1.0**) unless a caller supplies a real figure.
  **Do not derive it from checkpoint size:** an MoE reads only its active experts, and the unsloth
  27B's resident-but-unread vision tower implies 117% of peak bandwidth on a perfectly healthy run.
  A wrong tightening voids good rows.
- `SAFETY` = **3.0** (v1.1, raised from 2.0). Measured MTP accepted length on this node reaches
  2.69, so a legitimate spec-decode config can exceed a 2.0 bound and be fatally voided. 3.0 still
  catches the 449,358 row by 34×.

Worked: at c16 on 273 GB/s, 449,358 tok/s implies **0.0097 GB/token**. (v1.0 said 0.0006 — that
dropped the `level` factor from its own formula.)

## 5. Enforcement — record and flag, exit 4

A failing run is **still written**; the evidence must survive in the committed journal.

- Fatal verdict → `status=void`; suspect verdict → `status=suspect`; else the caller's status stands.
- **`crash` outranks validity** and is **non-valid for every consumer** (v1.1 — v1.0's filtering
  rules named only void/suspect, leaving a crash row carrying `over_roofline` to pass a status-only
  filter).
- **Consumers filter on `validity`, never on `status` alone** (v1.1), for the same reason.
- `bench.sh` exits **4** on any non-`ok` verdict, **including `suspect` alone** (v1.1, was
  unspecified); **3** on crash; crash wins when both occur. Callers must treat 4 as *"the row is
  written but not citable — continue"*, never as an abort.
- `promote.sh` refuses void/suspect supporting rows; `run_experiment.sh` refuses to median over
  them; `aggregate.py` hides them by default.

## 6. Status vocabulary

`measured` (invariants passed) · `keep` · `discard` · `crash` · `suspect` · `void`.

## 7. Historical rows

315 rows across 15 campaigns (v1.0 said 313 — the ctx merge added two). 309 have retained bundles;
**6 are permanently unauditable, the ceiling on how much of this project's record can ever be
verified.** Backfill `req_counts`/`validity`/`knobs`; publish an audit; **status is adjudicated by
the orchestrator, not rewritten in bulk.**

Bundles are gitignored and absent from agent worktrees — read them from the main checkout.

## 8. Rules that still bind

`bash` or `python` via `uv`/`uvx`. `set -euo pipefail`. `.env` and `results/**/data/` never
committed. No agent runs docker, serves a model, or touches the GPU.


---

# v1.2 amendments (2026-08-19, post-verification)

Four independent verifiers reviewed the merged v1.1 implementation. These amendments are their
findings adjudicated. **Where v1.2 differs from v1.1, v1.2 wins.**

## A1. The token-budget clause is REMOVED

`low_sample` is now solely `successful < max(AHL_MIN_DATA, min(20, 4*level))`.

Two verifiers refuted the v1.1 rationale independently, by different methods. The clause fired
alone on exactly **3 of 693 bundles**, all three the same replicate bracket, whose measured CV of
**0.59-0.70%** makes it *more* reproducible than the majority of brackets on this node — three
false positives, zero true positives. Banding CV by token budget runs the wrong way
(0.70% under 2048 -> 1.28% above 20k), and correlation against measured reproducibility is
`r = -0.006`. Worse, coder completions carry ~1000 output tokens, so **3 requests clear a 2048
budget** and 10 of the 15 genuinely starved levels in the corpus would have passed it. The clause
did not merely fail to detect starvation, it approved it. `AHL_MIN_DATA` was doing all the work.

Retained for the record: v1.1's premise that *request count* does not predict reproducibility is
confirmed. The inference that *tokens* do was wrong. Neither predicts it on this corpus.

## A2. `survivorship` is REDEFINED

```
survivorship  <=>  incomplete > level  AND  incomplete/(ok+incomplete) > AHL_DISCARD_TOL (0.30)
```

v1.1's `incomplete >= successful` is arithmetically `successful <= level`, because the median
`incomplete` per level across the corpus is exactly `level - 1` — the in-flight set at stage end.
It therefore could not fire below a 50% discard rate, while the rule's own justification cites
32.4% (coder c16) and 46.2% (coder c32). 18 level-instances discarding 30-48% were graded `ok`.
The new form subtracts the steady-state in-flight set before judging, so it measures *excess*
discard — the actual bias — instead of sample size in disguise. It must not fire on an empty
level (`ok == 0 and incomplete == 0`).

## A3. New fatal verdict `no_output`

`successful > 0` but `tps` is null, non-finite, or `<= 0` -> **fatal**. There is currently a
ceiling on throughput and no floor: a serve emitting zero output tokens returns `validity=ok`
(verified with 200 successful requests at 0.0 tok/s). AGENTS.md records NemotronH doing exactly
this under think-off, so it is not hypothetical.

## A4. `errored` escalates

`errored/(successful+errored) > 0.50` -> **fatal** (was uniformly suspect). A level with 107,589
errors and 17 successes — a dead endpoint — carried the same severity as one with 11% errors.
This is the fingerprint of §0 defect (b) at *any* magnitude, and it is what catches a dead
endpoint whose reported tok/s happens to land under the roofline (the real 1,992.87 sibling row).

## A5. `na` is never `ok`, in the library too

`parse_validity("na")` returned `["ok"]` and `verdicts({})` returned `["ok"]`. §3 has said since
v1.1 that `na` means "could not be evaluated — never `ok`"; the library asserted the opposite, so
any consumer that parsed before checking was wrong by construction. An empty or unreadable bundle
now yields `na` with a **suspect** floor, never `ok`.

## A6. The harness must supply the roofline input, and must fail CLOSED

`bench.sh` never passed `--node-profile`, so §4 was **dead code on the vLLM path** — the two
host-process benchers passed it, the primary bencher did not. Separately, when the library call
failed, `bench.sh` defaulted `STATUS_FLOOR=ok` and exited 0: a `uv` hiccup produced a fully
citable row. Both are now required behaviour: pass the node profile, and treat any failure to
evaluate as **not citable** (floor `suspect`, exit 4). The host benchers already fail closed.

## A7. One classifier, and it gates on the level being cited

Six hand-rolled copies of the verdict classifier each tested membership against *level-tagged*
tokens, so `'no_data@c16' in {'no_data','over_roofline'}` was always false and **no consumer ever
reported a row as void**. Consumers use the library's `verdict_base`/`split_verdict`/
`parse_validity_pairs` through a single shared module. A promotion gates on the rows supporting
the objective it cites (chat c16 by default, falling back to the highest level actually run, since
the host launchers bench `levels=1` only); tokens tagged at other levels are reported, never
blocking; anything fatal at the cited level blocks absolutely.

## A8. The acceptance suite must test the SYSTEM, not agree with the library

Mutation testing found 16 surviving mutations: every v1.1 amendment (token clause, survivorship,
adjacency, level tagging, unrun-levels-not-zeros) and **every enforcement path** — the status
downgrade, exit 4, the library call itself, the promotion block, the default-view hiding, and the
Gate-3 handling could each be deleted with 121/121 green. Requirements now:

- Wiring tests **execute** the code path against a fixture bundle. A substring grep is not a test:
  `_needs("promote.sh", "void", "suspect")` passes on a comment saying they are unhandled.
- Fixtures must **vary** `output_token_count` (the helper hardcoded 256.0 for every level, so the
  token and request clauses agreed on 100% of fixtures) and must include more than one healthy
  real bundle (the false-positive defence was n=1).
- Level tagging must be asserted on tagged tokens. The compatibility helper returns tagged AND
  bare names, which makes the suite structurally unable to notice whether tagging exists.
- **A mutation harness is part of the suite.** A rule with no mutation that turns the suite red is
  an untested rule.

## A9. Gate 2 gets an acceptance predicate (scope EXPANDED, deliberately)

v1.0/v1.1 scoped §0 defect (c) out as a Gate-2 problem. Verification showed Gate 2 has no
acceptance predicate whatsoever: a literal `nan` score, a score computed over **37 of 14,042**
requested samples, and a missing results file all write an `accuracy.tsv` row and report **PASS**,
because only `lm_eval`'s exit code is consulted. Defect (c) — one of the three defects that
motivated this entire work — reproduces unchanged today.

This is now in scope. Gate 2 must reject a non-finite score, must compare lm-eval's **effective**
sample count against the requested one (`n-samples` is in every bundle) and fail below a stated
fraction, and must fail when no score was produced. `accuracy.tsv` gains the columns needed to
audit that after the fact, including the sample counts and the long-standing missing `conc`.

## A10. Consistency and honesty fixes

- `assess_bundle(discover=False)` vs the CLI's `discover=True` gave **opposite verdicts on the
  same evidence**, and the code comment stated the inverse of what the code did. The tested path
  must be the executed path: the caller's run-level list is authoritative everywhere; only the
  audit/migration path may opt into discovery, explicitly.
- The audit's private `unauditable` rule disagrees with the library on 5 rows, and §7's published
  "6 permanently unauditable" comes from that private rule rather than from the library.
- `tests/test_verdicts.py` names three tests `test_c_*` after §0 defect (c). They test a missing
  level JSON, which is unrelated. A reader sees all three defects green. Rename them: this is
  precisely the mechanism by which a project comes to believe it is protected when it is not.
- `SAFETY = AHL_ROOFLINE_SAFETY` binds at import, so the documented override path silently fails
  to move the public alias.
