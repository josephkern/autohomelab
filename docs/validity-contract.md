# Measurement-validity contract (v1.4)

The binding spec for the §1 work of [issue #1](https://github.com/josephkern/autohomelab/issues/1).
v1.0 authored 2026-08-19 as the fixed interface ten parallel agents built against; **v1.1 (same
day) folds in the eleven adjudications those agents' findings forced.** Where v1.1 differs from
v1.0, v1.1 wins; where v1.2 differs from v1.1, v1.2 wins; **v1.3 (2026-08-20, the status
vocabulary — last section of this file) wins over all of them.** The implementation matches v1.3.

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

> **SUPERSEDED IN PART — read the "v1.2 status" section at the end of this file before using this
> table.** This document is an amendment ledger: each section records what was believed when it was
> written, and later sections overrule earlier ones. Specifically, the `low_sample` token-budget
> clause below was **deleted** (v1.2 A1) and `survivorship` below is **not** the shipped rule
> (v1.2 A2, re-adjudicated after measurement — the shipped form is `ok > 0 and incomplete > ok`).
> `no_output` and `errored_fatal` are missing from this table entirely. The authority is the
> closing status section; the implementation is `scripts/lib/validity.py`, whose rule docstrings
> carry the measurements.

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

> **SUPERSEDED IN PART:** `SAFETY` is **3.0** (v1.1), and
> `bench.sh` did not pass `--node-profile` until v1.2 A6, so this check was dead on the
> primary bench path for the whole of v1.1.

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
- **A USAGE ERROR IS NOT A RESULT (v1.3).** The ladder `3 > 4 > 1 > 0` ranks outcomes of work that
  ran, and `1` is defined as *pre-measurement* — the serve or the smoke was attempted and failed.
  A refused INVOCATION attempted nothing, so it exits **2** (`validity.EXIT_USAGE`), outside the
  ladder, and still prints its one `MEDIAN` line. Reporting it as `1` told the caller a serve had
  been tried; exiting silently told a caller that parses stdout nothing at all.

## 6. Status vocabulary

> **AMENDED by v1.3 (2026-08-20), at the end of this file: `keep` is RETIRED and `discard` is
> redefined.** The v1.2 line read `measured · keep · discard · crash · suspect · void`; it is
> kept here as history, not as the vocabulary.

`measured` (invariants passed) · `discard` (a §7 orchestrator adjudication, signed in `notes`) ·
`crash` · `suspect` · `void`. **Five words.**

## 7. Historical rows

315 rows across 15 campaigns (v1.0 said 313 — the ctx merge added two; **317 as of 20260820**, see v1.3 for the current breakdown). 309 have retained bundles;
**6 are permanently unauditable, the ceiling on how much of this project's record can ever be
verified.** Backfill `req_counts`/`validity`/`knobs`; publish an audit; **status is adjudicated by
the orchestrator, not rewritten in bulk.**

Bundles are gitignored and absent from agent worktrees — read them from the main checkout.

**An adjudication is signed (v1.3).** `discard` is the only status a human sets by hand, and it is
set precisely where the invariants have nothing to say, so the authority behind it has to be
legible. A hand-set `discard` MUST carry

```
adjudicated@YYYYMMDD who: reason
```

in `notes` (reason ≥ 12 chars — the same rule as `AHL_PROMOTE_OVERRIDE`: an adjudication is an
argument, not a flag). The existing prose is kept; the stamp is appended, so the row stays
greppable, dated and attributed:

```
grep -h 'adjudicated@' results/*/*/*/results.tsv
python3 scripts/lib/validity.py status --tsv results/*/*/*/results.tsv   # 0 clean, 4 offenders
```

The write path never sets it: `bench_ds4.sh`/`bench_llamacpp.sh` hard-code `status="measured"` and
never read `$STATUS`, and both `run_experiment*.sh` refuse `STATUS=discard` on the usage rung. A
§7 adjudication may also leave a published `discard` standing over a **void** floor — five rows in
this corpus do — and the stamp is what records that the human saw the floor and ruled anyway.

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


---

## v1.2 status (2026-08-20) — implemented, with two corrections to the amendments themselves

All ten v1.2 amendments are implemented and merged. Two were wrong as written and were
re-adjudicated **after measuring**, which is the process this contract now expects of itself:

- **A2 was inert.** `incomplete > level` is unsatisfiable — GuideLLM bounds its in-flight set by
  the concurrency level (88.8% of levels sit at exactly `level-1`, max ratio 1.000), so the rule
  fired **zero times on 690 levels** and missed all 53 level-instances it was written to catch.
  The shipped rule is **`ok > 0 and incomplete > ok`** (majority discard: the published mean is an
  average over a minority of the work started). The alternative was measured first — a 30% discard
  threshold flags 19 of 23 coder rows, which is a claim about the measurement METHOD, not a
  per-row defect signal. The systemic 30-48% coder discard is recorded in the AGENTS.md lab notes
  and the audit instead of being flagged every campaign. **What the rule does not catch is stated,
  not implied.**
- **A4 needed a distinct token.** Severity must be readable from the persisted `validity` string
  alone, so the fatal error band is its own base token `errored_fatal`, not `errored` re-graded.

**A9 (Gate 2) is implemented.** `scripts/eval_validity.py` supplies the predicate: `no_score`,
`nonfinite`, `short_sample` (effective < 99% of requested) fatal; `zero_score`, `no_samples`
suspect. Task-tagged tokens (`nonfinite@mmlu`) mirroring Gate 3's level tags, the same
void/suspect vocabulary, the same 3 > 4 > 1 > 0 exit ladder. Verified: a `nan` score, a
37-of-14,042 run, and a missing results file each now record a row and **fail** Gate 2, where all
three previously reported PASS. `accuracy.tsv` is 16 columns and finally carries `conc`.

Deliberately excluded from the Gate-2 predicate: any comparison of a score against a reference or
a floor. At `LIMIT=100` the binomial SE is ~4.3 points, wider than the ~1% KEEP tolerance, so a
threshold on the VALUE would imply a precision the sample size cannot deliver. This is a validity
check, not a tolerance test.

### Corpus under final v1.2

315 rows: **283 ok / 10 suspect / 22 void floor / 6 unauditable**; `status` remains
`291 measured / 12 crash / 6 discard / 6 void`, the six being hand-adjudicated per §7.
76 accuracy rows: 73 ok, 3 `zero_score@gsm8k`, and `conc` backfilled from each bundle
(74 at c16, **2 at c4** — see below).

### A correction to the record, found by implementing A9

The AGENTS.md follow-up asserted every accuracy row is c16 because nothing ever overrode `CONC`.
The bundles refute it: two ds4 rows ran at `num_concurrent=4`. This matters beyond bookkeeping —
those two rows are the 60.0 and 76.0 gsm8k scores in the tracked `config_hash` collision, and both
sit at **c4**, so concurrency does not explain that 3.7-sigma spread. `conc` was backfilled from
each bundle's own `model_args`, never stamped.

---

# v1.3 (2026-08-20) — the status vocabulary, adjudicated

One change, decided on the record rather than on taste. **`keep` is RETIRED. `discard` is RETAINED
and redefined.** Corpus at the time of the ruling: **317 rows — 284 `measured` / 12 `crash` / 8
`suspect` / 7 `void` / 6 `discard`.**

## Why `keep` goes

- **It was never written: 0 of 317 rows**, across 15 campaigns and every backend.
- **Wrong grain.** A keep verdict is a statement about a CONFIG, decided on the *median of N=3*
  benches. `status` is a property of ONE row. There is no row that is "the kept one", so the
  column could never hold the verdict even in principle.
- **Wrong time.** `bench.sh` writes each row as that row finishes, and §7 forbids rewriting a
  published row afterwards. At the only moment the column can be written, the comparison that
  would justify `keep` has not happened yet.
- Where the decision actually lives, and stays: `run_experiment.sh`'s `MEDIAN` line,
  `tune_status.py`'s ranking, and the campaign `logbook.md`.

Retired means *refused*, not merely undocumented: `STATUS_VOCAB` is five words, `check_status()`
and therefore `apply_status()` raise on `keep` with its retirement notice, and both runners reject
`STATUS=keep` before serving anything.

## Why `discard` stays

One row settles it. **`20260809-183024-chat`** (cfg `653a8d9c`, the FF711 `NP=32` bench) carries
`validity=survivorship@c32` and classifies **`valid` at c16 — the tuning objective**. It is
rejected because `NP=32 × CTX_PER_SLOT=12288` drove total context to 393,216 (~25 GiB KV) and
over-committed unified memory into swap, and because it changes two things at once. **No invariant
can see swap** — it leaves no trace in a GuideLLM level json. That class — numbers the rules cannot
fault but a human can (contamination, confounded design, swap) — is non-empty and unrecoverable
from `validity`.

But `discard` is not a bench-time verdict, and never was: `bench_ds4.sh` and `bench_llamacpp.sh`
hard-code `status="measured"` and never read `$STATUS`, and **all six** `discard` rows were applied
by later adjudication commits — exactly what §7 sanctions. So it is redefined as **an orchestrator
adjudication under §7, applied to the journal after the fact**, and it must be signed (§7 above).
The six existing rows were normalised to the stamp form on 20260820: `notes` only, no other field
touched, no `status` changed.

## What this does not change

`apply_status()` still downgrades a hand-set `discard` on the WRITE path (fatal → `void`, suspect →
`suspect`). The §7 hand adjudication is the deliberate exception to that, and the stamp is its
record — which is why the two can disagree in the journal without either being a defect.


---

# v1.4 (2026-08-20) — the spec catches up with the implementation

A documentation pass found this file behind the code **by exactly the mechanism the project exists
to prevent**: §3's table lacked two verdicts that had been shipping since v1.2, and two later
additions were not here at all. The v1.2/v1.3 blocks describe the reasoning; the tables did not
follow. That is the 16-vs-20-column drift, in the binding spec, three weeks after we wrote the
lab note about it. It is recorded rather than quietly fixed.

## The complete verdict vocabulary (supersedes §3's table)

| token | rule | severity | scope |
|---|---|---|---|
| `ok` | all checks pass | — | row-wide |
| `na` | rules could not be evaluated — **never `ok`** | — | row-wide |
| `no_data` | a run level has `successful < AHL_MIN_DATA` (5), or its json is missing/unparseable | fatal | per level |
| `over_roofline` | tok/s above the §4 ceiling | fatal | per level |
| `no_output` | `successful > 0` but tok/s null / non-finite / `<= 0` | fatal | per level |
| `errored_fatal` | `errored > 50%` of `successful + errored` | fatal | per level |
| `low_sample` | `successful < max(AHL_MIN_DATA, min(20, 4*level))` | suspect | per level |
| `errored` | `errored` between 10% and 50% | suspect | per level |
| `survivorship` | `ok > 0 and incomplete > ok` (majority discard) | suspect | per level |
| `nonmonotonic` | a run level >10% below the immediately preceding one | suspect | row-wide |
| `incomplete_run` | the sweep was interrupted before it finished | suspect | **row-wide** |

`errored_fatal` is a distinct base token, not a re-grading of `errored`: severity has to be
readable from the persisted `validity` string alone.

**`incomplete_run` must be row-wide**, and the reason is a defect it was created to fix.
`citability.classify_row` places its `status` checks inside `if level is None`, so at level scope
`status` is ignored entirely — an interrupted sweep with `status=suspect` classified **valid at
c16**, and the promotion gate reported `suspect=0`, leaving no trace of the interruption in the
artifact. Only a row-wide token survives the level-scoped reading a gate uses. It is `suspect`,
not fatal: the levels that landed are real data, and voiding them would be the mirror-image lie.

Callers must not hand-assemble a verdict string. `add_verdict()` (shim: `ahl_add_verdict`) owns
ordering, dedupe and the `ok`/`na` placeholder rule; it refuses an unknown token and refuses to
level-tag a row-wide one, and the shim fails closed.

## `config_hash` for host-process backends: the `hp3-` scheme

A vLLM row's `config_hash` is still `sha256` of the runbook. A **host-process** row's is
`hp3-<8hex>` over a canonical document built from the served process: argv from
`/proc/<pid>/cmdline` (NUL-safe; repeated flags carry ordinals because llama.cpp's
`--override-tensor` is first-match-wins), the tuning environment from `/proc/<pid>/environ`, and
the engine binary via `/proc/<pid>/exe` — **not** a git SHA of a source tree, which identifies a
directory that may not be what is running. Model files are identified by content, not by basename:
`snapshots/rev-AAAA/model.gguf` and `rev-BBBB/model.gguf` are different configs.

`eval.sh` computes the same identity for a host stub, so a config's Gate-2 and Gate-3 rows join.
A stub with **no engine found on the port** records `stub-<8hex>` — labelled and warned, never a
bare hex that could group with a served row. Pre-`hp3` rows keep bare hex and never group with
`hp3-` rows; that is correct, because they were never *proven* to be the same config.

## §5's promotion sentence is WITHDRAWN

§5 said: *"`promote.sh` refuses void/suspect supporting rows."* That has been false since the gate
became objective-scoped. What it actually does: **block** on any row fatal at the cited level, on
any `crash` at that level, or on zero valid rows; **report** everything else — including `suspect`
rows and problems at other levels — without blocking. Do not restate the withdrawn sentence; it is
precisely the kind of stale claim that convinces a reader a hole cannot exist.

## Corrections to earlier sections

- v1.3's "12 runbook pairs collapse to 6" is wrong: **12 pairs — 24 files — collapse onto 12
  configs.** (`research/review/POWER-analysis.md` §7.1(8) repeats the error.)
- The claim that two ds4 GGUFs share a byte size and differ only in content is **unverifiable from
  this repo** and is not what the code keys on. The demonstrated defect is basename collision.

## Standing scope limits

Gate 2's predicate cannot see **placeholder-filled** items: lm-eval substitutes a placeholder for
a null response and counts it as answered, so a run where 17-19% of items returned nothing scored
`samples=100/100`, a finite non-zero score, and `validity=ok` — measured on live hardware
20260820. Detecting it needs `--log_samples`, which the power analysis wants independently for
pairing. One flag closes both.

No p-value may enter this contract until the null experiment specified in
`research/review/POWER-analysis.md` §7.2 has run: the proposed McNemar gate would reject a config
compared against itself, because the observed same-config drift implies ~53 net flipped items.
