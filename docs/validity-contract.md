# Measurement-validity contract (v1.1)

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
