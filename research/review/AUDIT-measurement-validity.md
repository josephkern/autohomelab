# Audit — measurement validity of the published record

Forensic pass over every benchmark row this project has published, against
[`docs/validity-contract.md`](../../docs/validity-contract.md) **v1.1** §3. Issue #1 §1 asks the
question; this answers it with the evidence on disk.

- **Tool:** `scripts/audit_results.py` (read-only; all rules come from `scripts/lib/validity.py`,
  which per contract §1 is the only implementation).
- **Population:** 315 rows in 15 `results.tsv` journals. The review issue quotes 313; the two extra
  are `20260819-191404-chat` and `20260819-192032-chat`, added to `unsloth/Qwen3.8-27B-NVFP4` after
  the issue was written. Neither changes any conclusion below.
- **Evidence:** 693 retained `level_c*.json` bundles under `results/*/*/*/data/`.
- **Reproduce:** `uv run scripts/audit_results.py --data-root <checkout-with-bundles>`.
  The roofline is now **armed by default** — `gpu.mem_bw_gbs = 273` is in the node profile, so
  `--mem-bw` is no longer needed.
- **Not done:** no docker, no serve, no GuideLLM, no lm-eval, no GPU. Nothing was written to any
  `results.tsv`; status adjudication is the orchestrator's per contract §7.

> **Revision note.** This report was first written against contract v1.0 and reported
> 124 ok / 169 suspect / 16 void. v1.1 adopted this audit's §6 recommendation (token-budget
> `low_sample`, the new `survivorship` verdict, level-tagged tokens, adjacent-only
> `nonmonotonic`, `SAFETY` 3.0, roofline armed). Everything below is regenerated under v1.1.
> **The void set is bit-identical across the two versions** — the recalibration moved 168 rows
> out of `suspect` and did not move a single row into or out of `void`.

---

## 1. Headline

| verdict | rows | share |
|---|---:|---:|
| `ok` — all invariants pass | **280** | 89% |
| `suspect` — one or more suspect verdicts | **13** | 4% |
| `void` — one or more fatal verdicts | **16** | 5% |
| unauditable — bundle gone, verdict unknowable forever | **6** | 2% |
| **total** | **315** | |

**Nine out of ten published rows clear the contract.** The 16 void rows are the ones a reader must
not cite; §2 says which promotions touch them. The 13 suspect rows are named in full in §4.

Bundle retention is the record's strongest property: **309 of 315 rows (98%) are still auditable**.
The six that are not bound how much of the project's history can ever be verified:

| run_id | campaign | status | why unauditable |
|---|---|---|---|
| `20260613-105041` | RedHatAI/Qwen3-8B-NVFP4 | crash | `data=na` — no bundle was ever written |
| `20260616-180701-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B | crash | bundle dir empty |
| `20260712-144815-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | crash | bundle dir empty |
| `20260721-164941-chat` | antirez/DeepSeek-V4-Flash | discard | bundle dir empty |
| `20260721-164944-chat` | antirez/DeepSeek-V4-Flash | discard | bundle dir empty |
| `20260721-164948-chat` | antirez/DeepSeek-V4-Flash | discard | bundle dir empty |

All six are already `crash` or `discard`, so nothing citable is lost. **2% is the permanent audit
ceiling on this record.** Carrying `req_counts` in the committed journal (contract §2, now shipped)
is what stops that number growing.

---

## 2. Promotion risk — does any `_final` rest on an invalid row?

Two questions, two answers. They are different questions and the broader one must not bury the
sharper one.

### 2a. SHARP — whose published percentages are computed from void rows?

**Two.** Both quote a throughput gain in their own `# Result:` header where *both operands* are
rows the contract calls `void`. These are the ones to act on.

#### `runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/VLLM-23-RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B_NVFP4_final.sh`

> `# Result: ... coder c16=53.2/c32=22.2 (+43% vs baseline).`

| operand | row | req_counts (ok/inc/err) | v1.1 verdict |
|---|---|---|---|
| 53.23 / 22.23 (candidate) | `20260617-035335-coder` | `c1:3/1/0; c4:7/4/0; c8:9/8/0; c16:8/16/0; c32:4/31/0` | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c16+survivorship@c32` |
| 37.26 (baseline) | `20260615-180752-coder` | `c1:3/0/0; c4:5/3/0; c8:6/7/0; c16:6/15/0; c32:1/31/0` | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16+survivorship@c32` |

53.23 / 37.26 = **+42.9%**, matching the header exactly. The c32 figure of 22.23 is the mean of
**four** completed requests while 31 were discarded; the baseline c32 of 9.99 is the mean of **one**.
Both rows are still `status=measured`.

#### `runbooks/nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4/VLLM-24-nvidia_NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B_NVFP4_final.sh`

> `# Result: ... coder c32 70.7->114.1 (+61%)`

| operand | row | req_counts | v1.1 verdict |
|---|---|---|---|
| 114.06 (candidate) | `20260709-090400-coder` | `c1:4/1/0; c4:11/3/0; c8:17/8/0; c16:17/16/0; c32:17/32/0` | `no_data@c1+low_sample@c4+low_sample@c8+low_sample@c16+low_sample@c32+survivorship@c32` |
| 70.69 (baseline) | `20260709-055023-coder` | `c1:3/0/0; c4:9/4/0; c8:13/7/0; c16:17/15/0; c32:11/32/0` | `no_data@c1+low_sample@c4+low_sample@c8+low_sample@c16+low_sample@c32+nonmonotonic+survivorship@c32` |

114.06 / 70.69 = **+61.4%**, matching. Both c32 means discard roughly two-thirds of the requests
they started. Both rows are `status=measured`.

### 2b. BROAD — whose supporting rows include anything non-`ok`?

**Eight of fifteen** finals are flagged `AT RISK` by the driver. Broken down by what actually
triggers the flag:

| final | void rows | suspect rows | flagged by |
|---|---:|---:|---|
| `VLLM-27-Inferact_Qwen3.8-27B_NVFP4_final.sh` | 1 | 0 | void |
| `VLLM-23-RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B_NVFP4_final.sh` | 1 | 0 | void |
| `VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` | 2 | 0 | void |
| `VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` | 1 | 0 | void |
| `VLLM-23-RedHatAI_gemma-4-31B-it_NVFP4_final.sh` | 1 | 0 | void |
| `VLLM-24-nvidia_NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B_NVFP4_final.sh` | 1 | 0 | void |
| `VLLM-25-unsloth_Qwen3.6-35B-A3B-NVFP4-Fast_final.sh` | 1 | 0 | void |
| `VLLM-23-RedHatAI_Qwen3-Coder-Next_NVFP4_final.sh` | 0 | 1 | **suspect only** |

So: **7 finals have a void supporting row; 1 more (`Qwen3-Coder-Next`) is flagged on a single
suspect row** (`20260620-074011-coder`, `nonmonotonic+survivorship@c32`). Seven are clean:
both `Qwen3-8B` finals, `VibeThinker-3B`, both `Qwen3-Next-80B` finals, `unsloth/Qwen3.6-27B`,
and `unsloth/Qwen3.8-27B`.

Of the 7 void-touching finals, **4 are touched only by a `hang` row** — a GB10 wedge where
GuideLLM never wrote `level_c16.json`, so the level scores `no_data@c16`:
`VLLM-23-RedHatAI_Qwen3.6-35B-A3B` (2 rows), `VLLM-24-RedHatAI_Qwen3.6-35B-A3B`,
`VLLM-25-unsloth_Qwen3.6-35B-A3B-NVFP4-Fast`. Those are records of a crash, not corrupt data, and
each promotion has 3–8 valid c16 rows in the same bracket.

*(Note for the orchestrator: your message said the driver flags five. On `9e2884c` merged into this
branch it flags eight — the seven void-touching finals plus `Qwen3-Coder-Next` on a suspect row.
Reproduce with `uv run scripts/audit_results.py --data-root <checkout>` and grep `AT RISK`.)*

### 2c. The tuned objective itself is sound

The decision every campaign actually made — median `chat` c16 across an N=3 bracket — holds up.
Checking the c16 level of every chat row supporting every `_final`:

- **14 of 15** finals have ≥3 chat-c16 levels with no fatal verdict on that level — the N=3 bracket
  the charter requires. Counts run 57–392 successful.
- **3 of those 14** also carry a chat row whose c16 is `no_data@c16` — the `hang` rows above. None
  of the three promotions depended on them.
- **1 of 15** — `VLLM-23-RedHatAI_Qwen3-Coder-Next_NVFP4_final.sh` — rests on a **single** valid
  chat-c16 row (`20260620-072425-chat`, `c16:158/15/0`). It was a baseline-wins campaign, so no N=3
  bracket was ever run on the promoted config. The number is valid; the charter's N=3 rule was not
  applied to it.

**So: no promotion's speed ranking is refuted by this audit. Two promotions' published gain claims
are.** The configs are probably still the right ones to serve; the percentages printed on them are
not citable.

### 2d. The provenance gap that made this hard

Nothing machine-readable links a `_final.sh` to its supporting rows. `status` is *never* `keep` —
the vocabulary across 315 rows is `measured` (297), `crash` (12), `discard` (6). Every keep/discard
decision lives in prose in a logbook or a runbook header. This tool reconstructs the link by
regex-matching `promoted from <path>.sh` in the final's header and matching the `script` column.
**Contract §5's promote-time gate cannot be fully implemented until a promotion records its
supporting `run_id`s** — and it should gate on the rows a promotion actually *cites*, at the levels
it cites, not on every row that shares a runbook path.

---

## 3. The three known defects, independently rediscovered

Required cross-check. All three fall out of the bundles without being looked for.

| issue #1 defect | run_id | v1.1 verdict | evidence |
|---|---|---|---|
| c32 = 256.19 from **2** completed requests | `20260817-201312-coder` | **`no_data@c1+no_data@c32+…+survivorship@c16+survivorship@c32`** → void | `c1:3/0/0; c4:9/3/0; c8:12/7/0; c16:10/16/0; c32:2/31/0` |
| `tps_c16` = **449,358** from a dead endpoint | `20260818-135818-chat` | **`low_sample@c16+over_roofline@c16+errored@c16`** → void | `c1:20/0/0; c16:16/0/112069` |
| FF711 non-monotonic coder curve | `20260809-190152-coder` | **`no_data@c1+no_data@c4+no_data@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16`** → void | `c1:3/0/0; c4:4/3/0; c8:2/7/0; c16:5/15/0`; curve `27.57 → 121.23 → 47.72 → 56.42` |

**v1.1 closed the gap v1.0 left here.** `over_roofline@c16` now fires on the 449,358 row from
physics on a default run — `gpu.mem_bw_gbs = 273` is in the node profile, so the check is armed
rather than skipped. Under v1.0 that row was caught only by `errored`.

One residual, unchanged: the **sibling** MTP n=4 crash `20260818-142518-chat` (`tps_c16` =
**1,992.87**, `c16:17/0/107589`) is still **not** caught by `over_roofline`. With
`AHL_MIN_MODEL_GB = 1.0` and `SAFETY = 3.0` the c16 ceiling is 13,104 tok/s. With the real active
weight bytes of a 27B NVFP4 model (~13.5 GB/token) the ceiling is ~971 tok/s and it is refuted
immediately. It is still caught, by `errored@c16` and `low_sample@c16` — but by the weaker rules.
See §7.2.

---

## 4. Breakdowns

### By shape

| shape | ok | suspect | void | unauditable | n |
|---|---:|---:|---:|---:|---:|
| `chat(512/256)` | 269 | 11 | 7 | 5 | 292 |
| `coder(4096/1024)` | 11 | 2 | 9 | 1 | 23 |

The coder shape carries **9 of the 16 void rows on 7% of the population** — a 39% fatal rate against
2% for chat. Under v1.0 *zero* coder rows passed; v1.1's token budget correctly recognises that 8
coder requests generate four times the tokens of 20 chat requests (§5a).

### By campaign

| campaign | ok | suspect | void | unaud | n |
|---|---:|---:|---:|---:|---:|
| DavidAU/Qwen3.6-27B-FF711 (llama.cpp) | 16 | 4 | 1 | 0 | 21 |
| Inferact/Qwen3.8-27B-NVFP4 | 34 | 0 | 1 | 0 | 35 |
| RedHatAI/NVIDIA-Nemotron-3-Super-120B | 26 | 0 | 2 | 1 | 29 |
| RedHatAI/Qwen3-8B-NVFP4 | 27 | 1 | 2 | 1 | 31 |
| RedHatAI/Qwen3-Coder-Next-NVFP4 | 10 | 1 | 0 | 0 | 11 |
| RedHatAI/Qwen3.6-35B-A3B-NVFP4 | 38 | 0 | 4 | 0 | 42 |
| RedHatAI/gemma-4-31B-it-NVFP4 | 16 | 0 | 1 | 0 | 17 |
| WeiboAI/VibeThinker-3B | 11 | 0 | 0 | 0 | 11 |
| antirez/DeepSeek-V4-Flash (ds4) | 49 | 6 | 0 | 3 | 58 |
| nvidia/Nemotron-Labs-3-Puzzle-75B | 8 | 0 | 2 | 0 | 10 |
| nvidia/Qwen3-Next-80B-Instruct | 10 | 0 | 0 | 0 | 10 |
| nvidia/Qwen3-Next-80B-Thinking | 5 | 0 | 0 | 0 | 5 |
| unsloth/Qwen3.6-27B-NVFP4 | 4 | 0 | 1 | 0 | 5 |
| unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | 5 | 0 | 1 | 1 | 7 |
| unsloth/Qwen3.8-27B-NVFP4 | 21 | 1 | 1 | 0 | 23 |

Under v1.0 four campaigns had **zero** clean rows — FF711, Nemotron-3-Super-120B, gemma-4-31B, ds4 —
which were exactly the four slowest models on the node. That was the flat-20 threshold measuring
model speed, not data quality. Under v1.1 those four report 16/21, 26/29, 16/17 and 49/58 clean.

### By status

| journal status | ok | suspect | void | unaud | n |
|---|---:|---:|---:|---:|---:|
| `measured` | 280 | 11 | **6** | 0 | 297 |
| `crash` | 0 | 1 | 8 | 3 | 12 |
| `discard` | 0 | 1 | 2 | 3 | 6 |
| `keep` | — | — | — | — | **0** |

**Zero rows are marked `keep`.** The brief asks how many `keep` rows fail the invariants; the answer
is that the status column has never been used to record an adjudication.

#### The six `measured` rows that are fatal — re-verified under v1.1, list UNCHANGED

The thresholds moved; this list did not. All six are `no_data`-driven (a level with fewer than 5
completed requests, which `AHL_MIN_DATA` holds flat at 5), so the v1.1 recalibration could not and
did not touch them.

| run_id | campaign | v1.1 verdict | worst level |
|---|---|---|---|
| `20260615-180752-coder` | RedHatAI/Nemotron-3-Super-120B | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16+survivorship@c32` | c32: 1 ok / 31 incomplete |
| `20260617-035335-coder` | RedHatAI/Nemotron-3-Super-120B | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c16+survivorship@c32` | c32: 4 ok / 31 incomplete |
| `20260614-211454-coder` | RedHatAI/gemma-4-31B-it | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16+survivorship@c32` | c32: 1 ok / 31 incomplete |
| `20260709-055023-coder` | nvidia/Puzzle-75B | `no_data@c1+low_sample@c4+low_sample@c8+low_sample@c16+low_sample@c32+nonmonotonic+survivorship@c32` | c1: 3 ok |
| `20260709-090400-coder` | nvidia/Puzzle-75B | `no_data@c1+low_sample@c4+low_sample@c8+low_sample@c16+low_sample@c32+survivorship@c32` | c1: 4 ok |
| `20260625-053128-coder` | unsloth/Qwen3.6-27B | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+survivorship@c1+survivorship@c16+survivorship@c32` | c1: **1** ok |

All six are coder rows. Four are cited in a promoted `_final.sh` or a logbook comparison.

#### All 13 suspect rows

Small enough to name in full, which is the point of the recalibration.

| run_id | campaign | status | verdict | req_counts |
|---|---|---|---|---|
| `20260809-164806-chat` | DavidAU/FF711 | measured | `low_sample@c1` | `c1:7/0/0;c16:37/15/0` |
| `20260809-165428-chat` | DavidAU/FF711 | measured | `low_sample@c1` | `c1:7/0/0;c16:37/15/0` |
| `20260809-170056-chat` | DavidAU/FF711 | measured | `low_sample@c1` | `c1:7/0/0;c16:36/15/0` |
| `20260809-183024-chat` | DavidAU/FF711 | discard | `survivorship@c32` | `c1:12/0/0;c16:23/15/0;c32:22/31/0` |
| `20260613-123642-coder` | RedHatAI/Qwen3-8B | measured | `survivorship@c32` | `c1:7/0/0;…;c32:30/32/0` |
| `20260620-074011-coder` | RedHatAI/Qwen3-Coder-Next | measured | `nonmonotonic+survivorship@c32` | `c1:7/0/0;…;c32:24/31/0` |
| `20260721-171814-chat` | antirez/ds4 | measured | `low_sample@c4+nonmonotonic` | `c1:12/0/0;c4:10/3/0` |
| `20260721-172459-chat` | antirez/ds4 | measured | `low_sample@c4` | `c1:12/0/0;c4:9/3/0` |
| `20260721-173132-chat` | antirez/ds4 | measured | `low_sample@c4` | `c1:12/0/0;c4:9/3/0` |
| `20260721-173859-chat` | antirez/ds4 | measured | `low_sample@c4` | `c4:11/3/0` |
| `20260721-174211-chat` | antirez/ds4 | measured | `low_sample@c4` | `c4:12/3/0` |
| `20260721-174538-chat` | antirez/ds4 | measured | `low_sample@c4` | `c4:12/3/0` |
| `20260818-142518-chat` | unsloth/Qwen3.8-27B | crash | `low_sample@c16+errored@c16` | `c1:20/0/0;c16:17/0/107589` |

Six of the thirteen are one ds4 bracket at c4 (9–12 requests against a floor of 16), and three more
are one FF711 bracket at c1. **Two clusters account for 9 of 13 suspects** — a re-measure of each
would clear most of the remaining doubt in the whole journal.

---

## 5. Defects nobody was looking for

### 5a. The coder shape has never once reached 20 requests at c1 — and it is arithmetically impossible that it could

At concurrency 1 the number of requests a stage can complete is
`max_seconds × tok/s ÷ mean_output_tokens`. For `coder(4096/1024)` at `MAX_SECONDS=180`, reaching
20 requests requires **113.8 tok/s at c1**. The fastest c1 ever recorded on this node, in any shape,
on any model, is **80.28** (`20260712-182735-coder`). The bar has never been reachable and never
will be on this hardware.

The record confirms it exactly: **22 of 22 coder c1 levels are below 20 successful.** Distribution:
min 1, p25 3, median 7, max 13. Raising `MAX_SECONDS` to 600 drops the bar to 34.1 tok/s and 4 of 4
rows at 600 s are still under it.

| shape | max_s | tok/s needed for n=20 at c1 | levels under 20 |
|---|---:|---:|---|
| chat | 180 | 28.4 | 139 / 249 |
| chat | 300 | 17.1 | 13 / 30 |
| chat | 600 | 8.5 | 0 / 1 |
| coder | 180 | **113.8** | **18 / 18** |
| coder | 600 | 34.1 | **4 / 4** |

**This finding is what condemned the flat-20 rule, and v1.1 acted on it.** The right reading is not
that coder c1 numbers are invalid — 8 coder requests generate 8,192 output tokens, four times what
20 chat requests produce — but that **request count was measuring model speed, not measurement
quality.** Under v1.1's token budget, 11 of 22 coder c1 levels pass; the ones that fail fail on
`no_data` (1–4 completed requests), which is a real problem.

What survives as a live caveat: you cannot run a request-level statistical argument on coder c1.
With a median of 7 completed requests there is no meaningful within-level distribution, and any
`_final.sh` header quoting a coder c1 figure is quoting a handful of samples.

### 5b. GuideLLM's `successful.mean` is survivorship-biased, and the bias grows monotonically with concurrency

*(This analysis is unchanged by v1.1 — it is a property of the bundles, and it is what motivated the
new `survivorship` verdict.)*

GuideLLM averages **only** requests that completed inside the stage window. Requests still in flight
at the deadline are `incomplete` and silently dropped. Because in-flight requests are by
construction the *slow* ones, the reported mean is biased **high**, and the bias scales with how
many get dropped:

| shape | level | levels | total ok | total incomplete | share of started requests discarded |
|---|---|---:|---:|---:|---:|
| chat | c1 | 280 | 5,919 | 6 | 0.1% |
| chat | c4 | 30 | 1,796 | 91 | 4.8% |
| chat | c8 | 24 | 2,900 | 169 | 5.5% |
| chat | c16 | 225 | 38,831 | 3,363 | 8.0% |
| chat | c32 | 24 | 6,515 | 747 | 10.3% |
| coder | c1 | 22 | 136 | 7 | 4.9% |
| coder | c4 | 22 | 376 | 73 | 16.3% |
| coder | c8 | 22 | 572 | 161 | 22.0% |
| coder | c16 | 21 | 672 | 322 | **32.4%** |
| coder | c32 | 20 | 732 | 628 | **46.2%** |

At coder c32 the harness throws away nearly half the work it started and reports the mean of the
faster half. This is **directional bias, not noise**, and it means a low `MAX_SECONDS` does not
merely add variance — it inflates the number.

It also explains the coder curve inversions the project has been reading as engine behaviour:
throughput does not actually fall between c8 and c32, the *estimator* stops being able to keep up.
That is the mechanism behind issue #1's "non-monotonic curve" symptom.

**v1.1 adopted the proposed `survivorship` verdict** (`incomplete >= successful`, suspect). Where it
fires is a clean confirmation of the gradient above:

| shape | level | levels flagged |
|---|---|---|
| chat | c32 | 1 of 24 |
| coder | c1 | 1 of 22 |
| coder | c8 | 3 of 22 |
| coder | c16 | 6 of 21 |
| coder | c32 | **9 of 20 (45%)** |

Nothing fires at chat c1–c16, which is where the entire tuning objective lives. The verdict is
precisely targeted at the levels where the estimator is untrustworthy.

### 5c. The invisible-knob problem is worse than reported, and it is in the tuning objective

Issue #1 notes a baseline at `MAX_SECONDS=600` and a finalize at the 180 default in the coder shape.
The `chat` shape — the shape every keep/discard decision is made on — has the same problem, with
**three** stage lengths inside one campaign:

`Inferact/Qwen3.8-27B-NVFP4`, chat(512/256):

| rows | max_seconds | role |
|---:|---:|---|
| 1 | 600 | `20260815-174443-chat` — the campaign **baseline** |
| 30 | 300 | the entire tuning bracket, `20260816-030252` → `20260816-220549` |
| 1 | 180 | `20260817-195708-chat` — the **finalize** full sweep |

Every one is `status=measured`, every one is `ok` under v1.1, and the journal's `max_s` column
records each correctly. Nothing ever compared them. The campaign's headline improvement is a 300 s
number divided by a 600 s number, and the promoted config's published sweep is a third, 180 s
measurement. Given §5b, longer stages are not merely better-sampled but *less biased*, so these are
not interchangeable — **and no verdict in the contract catches it, because each row is individually
fine.** The `knobs` column now makes it visible; nothing yet makes it fail.

Good news alongside it: **`max_s` in the journal matches the bundle's `args.max_seconds` on all 309
auditable rows — zero mismatches.** The knob was recorded honestly the whole time; nothing read it.

### 5d. `tps_c*` carries an undocumented non-numeric sentinel

The throughput columns contain three kinds of value: numbers, `na` (868 cells), and **`hang`
(13 cells)**. All 13 sit on `crash` rows where the GB10 wedge killed GuideLLM before it wrote the
level file, which is why 7 rows publish a `tps_c16` cell with no `level_c16.json` behind it. Any
consumer doing `float()` on a throughput column breaks or silently drops those rows.

**v1.1 documented `hang` in §2 and the library ships `parse_tps()` to handle it** — closed, but
worth keeping in the record as the reason those 7 rows score `no_data@c16` rather than vanishing.

### 5e. Journal fidelity is perfect, and so are the reproducibility fundamentals — say so

Two independent checks, both clean:

- **688 of 688** comparable `tps_c*` cells match their bundle's measured mean to within 0.1%. The
  journal has never been hand-edited away from its evidence. (The two exceptions are the MTP n=4
  crash cells deliberately blanked to `na`, which is exactly the right correction.)
- Across all 690 audited levels: **`random_seed` is 42 on every one**, `guidellm_version` is `0.6.0`
  on every one, and each shape's synthetic `--data` spec is byte-identical across every campaign and
  four vLLM minor versions. **Zero rows have levels that disagree with each other on any knob.**

Whatever else this audit found, the harness has never silently changed its stimulus, and the journal
has never misreported what the bundle says.

### 5f. Roofline caveat: speculative decoding still competes with the §4 bound

FF711 `20260809-190152-coder` measured c4 = 121.23 tok/s on a model AGENTS.md documents at
21.18 GB/token. With the true bytes, the §4 bound at v1.0's `SAFETY = 2.0` was
`2 × 4 × 273 / 21.18 = 103.1` — a **false positive** on a legitimate MTP run, whose real ceiling at
2.69 accepted tokens is ~138.7.

**v1.1 raised `SAFETY` to 3.0**, which clears that case (154.7). The structural point stands: `SAFETY`
is doing the job of a speculation factor. Three covers the accepted lengths seen so far; a deeper
draft would need more. Tie it to `1 + num_speculative_tokens` when the config is known, rather than
relying on a constant to absorb it — otherwise a future MTP n=4 config with good acceptance becomes
a false alarm at exactly the moment the roofline gets tight enough to be useful.

---

## 6. `low_sample` calibration — what was adopted, and what it measured

This section proposed the recalibration; **v1.1 adopted it**. Recorded here as evidence rather than
as options.

### 6a. The problem with the v1.0 rule

Distribution of `successful` per level across all 693 retained bundles:

| shape | level | levels | min | p10 | p25 | median | max |
|---|---|---:|---:|---:|---:|---:|---:|
| chat | c1 | 280 | 7 | 10 | 12 | **18** | 55 |
| chat | c4 | 30 | 9 | 11 | 26 | 55 | 118 |
| chat | c8 | 24 | 21 | 45 | 68 | 119 | 215 |
| chat | c16 | 225 | 16 | 42 | 73 | 173 | 392 |
| chat | c32 | 24 | 22 | 77 | 135 | 234 | 652 |
| coder | c1 | 22 | 1 | 3 | 3 | **7** | 13 |
| coder | c4 | 22 | 4 | 5 | 9 | 18 | 37 |
| coder | c8 | 22 | 2 | 7 | 12 | 26 | 60 |
| coder | c16 | 21 | 5 | 6 | 10 | 32 | 79 |
| coder | c32 | 20 | 1 | 2 | 11 | 34 | 96 |

The flat threshold of 20 sat **above the median** of chat c1 (18) and **above the maximum** of coder
c1 (13). It was not detecting an anomaly; it was drawing a line through the middle of the normal
operating distribution. Per level it fired on **174 of 302 c1 levels (58%)** against **10 of 253 c16
levels (4%)** — the objective the project actually tunes.

### 6b. The decisive evidence: request count does not predict reproducibility

Every replicate bracket in the journal (same journal, script, shape, `config_hash`, N≥3), coefficient
of variation of the reported tok/s, banded by sample count:

| successful per level | brackets | median CV | p90 CV |
|---|---:|---:|---:|
| n < 10 | 8 | **0.39%** | 1.87% |
| 10 ≤ n < 20 | 40 | 1.42% | 4.60% |
| 20 ≤ n < 50 | 43 | 0.56% | 2.57% |
| n ≥ 50 | 53 | 1.10% | 2.59% |

**No monotone relationship.** The least-sampled band is the *most* reproducible. A c1 level with
8–19 completed requests reproduces to ~1.2%, well inside the ±3% KEEP rule and an order of magnitude
inside the ~10% cross-session drift AGENTS.md already documents for this box.

The reason is that requests are the wrong unit. At c1 a single chat request is ~256 sequential decode
steps, so a level with 8 requests averages ~2,048 token-generation events. Estimator precision scales
with **tokens generated**, not requests completed — which is why 8 coder requests (8,192 tokens) beat
20 chat requests (5,120 tokens) despite looking four times worse by request count.

### 6c. Adopted rule and measured outcome

```
no_data      : successful < AHL_MIN_DATA (5)                     UNCHANGED — the load-bearing rule
low_sample   : successful × mean_output_tokens < 2048            precision arm
               OR successful < max(5, min(20, 4 × level))        coverage arm
survivorship : incomplete >= successful                          NEW (§5b)
```

Outcome on the full record, v1.0 → v1.1:

| | v1.0 (flat 20) | v1.1 (adopted) |
|---|---:|---:|
| ok | 124 (39%) | **280 (89%)** |
| suspect | 169 (54%) | **13 (4%)** |
| void | **16** | **16** |
| unauditable | 6 | 6 |

**The void set is bit-identical.** Not one row moved into or out of `void`, and all three §0 defects
remain caught — because none of them was ever detected by `low_sample`: the 2-request coder and the
FF711 row are `no_data` (threshold unmoved), and the 449,358 row is `over_roofline` + `errored`.
The recalibration cost zero detection power and removed 168 false alarms.

Per-level, the change lands where the analysis predicted:

| level | run levels | v1.0 flat-20 would flag | v1.1 `low_sample` |
|---|---:|---:|---:|
| c1 | 307 | 174 | **3** |
| c4 | 52 | 18 | 13 |
| c8 | 46 | 8 | 7 |
| c16 | 253 | 10 | **10** |
| c32 | 44 | 7 | 2 |

c16 — the tuning objective — is **unchanged at 10**. The rule stopped flagging structurally-thin c1
sentinels and kept every genuine c16 problem.

The token budget also proves its worth at the extremes. The smallest budget in the whole corpus,
per shape/level, lands on exactly the rows this audit condemns:

| shape/level | min budget | row | why it is that small |
|---|---:|---|---|
| chat c16 | **509** | `20260818-135818-chat` | the 449,358 dead-endpoint row — 16 "successful" requests returning **31.8** tokens each against a median of 43,434 for healthy chat c16 |
| coder c32 | **511** | `20260615-180752-coder` | one completed request, 31 discarded (Nemotron-3-Super baseline, cited in a promoted header — §2a) |
| coder c8 | **1,360** | `20260809-190152-coder` | the FF711 row, 2 completed of 9 |
| coder c1 | **1,408** | `20260625-053128-coder` | a single completed request |

Every one is one to two orders of magnitude below the median of its own cell, and the rule reaches
them without knowing anything about the model, the engine, or the shape.

---

## 7. Contract issues

### Closed by v1.1

1. ~~**§4's worked example does not fire.**~~ **CLOSED.** `gpu.mem_bw_gbs = 273` is now in
   `results/gb10-1988a9714b4e/node_profile.json`; `over_roofline@c16` fires on the 449,358 row on a
   default run.
2. ~~**Severity is per-row, so a starved c1 condemns a campaign's c16 objective.**~~ **CLOSED.**
   Verdict tokens now carry their level (`low_sample@c1`), so consumers gate on the level they cite.
3. ~~**`na` convention violated by `hang`.**~~ **CLOSED.** §2 documents the sentinel and
   `parse_tps()` handles it.
4. ~~**`low_sample` miscalibrated.**~~ **CLOSED** — see §6.
5. ~~**No rule for survivorship bias.**~~ **CLOSED** — `survivorship` verdict added.

### Still open

6. **`AHL_MIN_MODEL_GB = 1.0` is too loose to refute anything real.** At `SAFETY = 3.0` it puts the
   c16 ceiling at 13,104 tok/s, so the 1,992.87 tok/s dead-endpoint row passes the physical bound.
   The active-weight bytes are derivable from the model card for every campaign on record; the
   fallback should be the exception, not the norm.
7. **`SAFETY` is absorbing speculation** (§5f). Tie it to `1 + num_speculative_tokens` when the
   config is known.
8. **§5's promote-time gate is not fully implementable** (§2d). It requires knowing a promotion's
   supporting rows; nothing records them. Either `promote.sh` writes the `run_id`s into the
   `_final.sh` header, or the gate stays advisory. It should also gate on the **level** a promotion
   cites, now that tokens carry levels — otherwise a `no_data@c16` on a coder characterisation row
   blocks a promotion decided on chat c16.
9. **Nothing catches cross-row knob drift** (§5c). Three `MAX_SECONDS` values inside one campaign's
   chat bracket produced 32 individually-`ok` rows that are not comparable to each other. Every rule
   in §3 is per-row; comparability is a property of a *set* of rows. A `run_experiment.sh` /
   `promote.sh` check that all rows in a bracket share a `knobs` string would close it cheaply.
10. **`AGENTS.md` still documents the v1.0 rules — the exact drift its own "Schema history" note
    warns about.** Checked against `docs/validity-contract.md` v1.1 and the shipped library:
    - the "Validity verdicts" table gives `low_sample` as `successful < AHL_MIN_SUCCESSFUL`
      (default 20); the shipped rule is the token budget OR `max(5, min(20, 4*level))`;
    - `nonmonotonic` is described as "a higher concurrency level is >10% below a **lower** one";
      v1.1 made it **adjacent-only**;
    - there is no `survivorship` row in the table, and no mention that tokens carry their level
      (`low_sample@c1`);
    - "Validity knobs" lists only `AHL_MIN_DATA`, `AHL_MIN_SUCCESSFUL`, `AHL_MIN_MODEL_GB` —
      missing `AHL_MIN_TOKENS`, `AHL_DROP_TOL`, `AHL_ERR_TOL`, `AHL_ROOFLINE_SAFETY`;
    - the `knobs` example still uses the withdrawn `levels=1,16` encoding rather than `levels=1|16`;
    - the follow-up entry "`gpu.mem_bw_gbs` is absent from the existing node profile" is **closed** —
      it is present (273) and the roofline is armed.
    The reference and the contract disagreed for months on the column count; they now disagree on
    the rules. Same failure, one layer up.

---

## 8. Adapter review (requested)

The orchestrator rewired this driver onto the shipped library API via a rules-free adapter
(`_Stats`, `_level_stats_from_json`, `_missing_level`, `_by_level`, `_verdicts`, `_severity`,
`_status_for`, `_req_counts`, `_knobs`) and fixed `bucket()` to accept the library's `void`.
**Verdict: the translation is faithful.** Evidence:

1. **End-to-end equivalence, 309/309.** Recomputing every auditable row through the library's *own*
   bundle entry point — `validity.scan_bundle(bundle, run_levels, tps, discover=True)` →
   `validity.verdicts(...)` → `format_validity` / `format_req_counts` — reproduces the driver's
   `validity` and `req_counts` strings on **all 309 rows with zero disagreements**.
2. **`_severity` → `status_floor` is correct.** The library's floor vocabulary is `ok|suspect|void`;
   `bucket()` now maps `void` (and keeps the old `fatal` key harmlessly). Without that fix every
   fatal row would have raised `KeyError`, not been silently miscounted — so the pre-fix output
   could not have been wrong-but-plausible.
3. **`_missing_level` → `LevelCounts(missing=True)`** matches what `scan_bundle` constructs on
   `LevelParseError`, which is why the 7 `hang` rows score `no_data@c16` identically on both paths.
4. **The tok/s source differs, and it does not matter here.** `scan_bundle` overrides the bundle's
   tok/s with the journal cell when it parses as a number ("the journal cell is what a reader will
   actually cite"); the driver reads the bundle. I tested the divergence directly: **688 of 688
   comparable cells agree to within 0.1%** (§5e), so the two paths cannot disagree on this corpus.
   The one place it could matter is the hand-blanked MTP n=4 cell — and there the journal says `na`,
   so the override does not fire and the bundle's 449,358 is judged. Correct on both paths.

Two things I would change, neither of which affects any number in this report:

- **`_knobs()` reads `max_seconds`/`seed`/`gllm` from the first non-missing level only.** I tested
  this: **zero rows have levels that disagree on any knob**, so it is lossless on this corpus — but
  it is lossless by luck, not by construction. A row whose levels ran under different knobs would
  silently report only the first. The original implementation joined the distinct values.
- **The driver still hand-rolls the run-level union** (`tsv_levels | bundle_levels`) that the library
  now ships as `scan_bundle(..., discover=True)`. That is mechanism, not rules, so it does not
  violate §1 — but it is a second copy of an amendment that has already bitten once. `audit_row()`
  should call `scan_bundle` and delete `_level_stats_from_json` / `_missing_level` / `_by_level`.
  I left it alone this pass so the cross-check in (1) stayed genuinely independent.

---

## Appendix A — per-row verdicts

315 rows, ordered by `run_id`. `req_counts` is `successful/incomplete/errored` per run level;
`c<N>:na` for a level that was attempted but left no bundle. Generated by
`uv run scripts/audit_results.py --data-root <checkout> --format markdown`.

| run_id | model | shape | status | verdict | req_counts (ok/inc/err) |
|---|---|---|---|---|---|
| `20260613-105041` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | crash | `na` | `na` |
| `20260613-122100-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c4:109/3/0;c8:201/7/0;c16:331/14/0;c32:481/31/0` |
| `20260613-123642-coder` | RedHatAI/Qwen3-8B-NVFP4 | coder(4096/1024) | measured | `survivorship@c32` | `c1:7/0/0;c4:18/4/0;c8:27/7/0;c16:32/15/0;c32:30/32/0` |
| `20260613-130852-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:27/0/0;c16:333/16/0` |
| `20260613-131512-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:349/15/0` |
| `20260613-132132-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:351/16/0` |
| `20260613-134328-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | crash | `no_data@c16` | `c1:29/0/0;c16:na` |
| `20260613-140006-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:26/0/0;c16:334/15/0` |
| `20260613-140621-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:351/15/0` |
| `20260613-141244-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:354/15/0` |
| `20260613-142253-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:337/15/0` |
| `20260613-142915-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:355/15/0` |
| `20260613-143536-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:357/15/0` |
| `20260613-162600-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:26/0/0;c4:106/3/0;c8:199/7/0;c16:342/16/0;c32:522/31/0` |
| `20260613-181110-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c4:107/3/0;c8:202/7/0;c16:342/15/0;c32:522/31/0` |
| `20260613-193429-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:332/15/0` |
| `20260613-194052-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:347/15/0` |
| `20260613-194717-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:348/15/0` |
| `20260613-195822-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:329/15/0` |
| `20260613-200446-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:346/15/0` |
| `20260613-201110-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:347/15/0` |
| `20260613-202026-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:371/15/0` |
| `20260613-202649-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:392/15/0` |
| `20260613-203310-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/1/0;c16:392/15/0` |
| `20260613-205619-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:328/15/0` |
| `20260613-210243-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:344/15/0` |
| `20260613-210905-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:345/15/0` |
| `20260613-212313-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:336/15/0` |
| `20260613-212936-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:349/15/0` |
| `20260613-213556-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | crash | `no_data@c16` | `c1:29/0/0;c16:na` |
| `20260614-073625-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c4:114/3/0;c8:215/7/0;c16:387/15/0;c32:652/31/0` |
| `20260614-085507-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c4:106/3/0;c8:161/7/0;c16:233/15/0;c32:315/31/0` |
| `20260614-094220-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:230/15/0` |
| `20260614-094840-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:234/15/0` |
| `20260614-095503-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | crash | `no_data@c16` | `c1:39/0/0;c16:na` |
| `20260614-101218-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:230/15/0` |
| `20260614-101842-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:233/15/0` |
| `20260614-102501-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:234/15/0` |
| `20260614-110227-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:31/0/0;c16:202/15/0` |
| `20260614-110851-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:30/0/0;c16:201/15/0` |
| `20260614-111510-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:30/0/0;c16:201/15/0` |
| `20260614-112733-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:238/15/0` |
| `20260614-113357-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:244/15/0` |
| `20260614-114020-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:242/15/0` |
| `20260614-115245-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:226/15/0` |
| `20260614-115907-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:230/15/0` |
| `20260614-120527-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:233/15/0` |
| `20260614-121849-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:229/15/0` |
| `20260614-122508-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:234/15/0` |
| `20260614-123128-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:233/15/0` |
| `20260614-205253-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c4:28/3/0;c8:49/7/0;c16:76/16/0;c32:100/31/0` |
| `20260614-211454-coder` | RedHatAI/gemma-4-31B-it-NVFP4 | coder(4096/1024) | measured | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16+survivorship@c32` | `c1:2/0/0;c4:5/3/0;c8:7/8/0;c16:6/15/0;c32:1/31/0` |
| `20260614-213825-coder` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | coder(4096/1024) | crash | `no_data@c16` | `c1:9/1/0;c4:25/3/0;c8:36/7/0;c16:na` |
| `20260614-232113-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:73/15/0` |
| `20260614-232748-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:73/16/0` |
| `20260614-233424-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:73/16/0` |
| `20260614-234718-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:89/15/0` |
| `20260614-235353-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:91/16/0` |
| `20260615-000026-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:96/15/0` |
| `20260615-002424-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:71/15/0` |
| `20260615-003104-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:77/15/0` |
| `20260615-003745-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:77/15/0` |
| `20260615-005512-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:73/15/0` |
| `20260615-010146-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:74/16/0` |
| `20260615-010820-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:73/15/0` |
| `20260615-012003-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:59/15/0` |
| `20260615-012638-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:61/15/0` |
| `20260615-013315-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c16:60/16/0` |
| `20260615-175157-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c4:28/3/0;c8:38/7/0;c16:49/15/0;c32:63/31/0` |
| `20260615-180752-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | coder(4096/1024) | measured | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16+survivorship@c32` | `c1:3/0/0;c4:5/3/0;c8:6/7/0;c16:6/15/0;c32:1/31/0` |
| `20260616-031158-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:51/14/0` |
| `20260616-031839-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:48/15/0` |
| `20260616-032523-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:49/15/0` |
| `20260616-034532-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:15/0/0;c16:57/15/0` |
| `20260616-035153-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:15/0/0;c16:58/15/0` |
| `20260616-035814-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:16/0/0;c16:58/15/0` |
| `20260616-041612-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:47/15/0` |
| `20260616-042232-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:51/15/0` |
| `20260616-042857-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:50/15/0` |
| `20260616-044718-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:49/15/0` |
| `20260616-045342-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:50/15/0` |
| `20260616-050004-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:50/15/0` |
| `20260616-051829-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:48/15/0` |
| `20260616-052452-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:50/15/0` |
| `20260616-053112-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:51/15/0` |
| `20260616-063656-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:27/15/0` |
| `20260616-064321-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:26/15/0` |
| `20260616-064943-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:27/15/0` |
| `20260616-071209-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:50/15/0` |
| `20260616-071831-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:47/16/0` |
| `20260616-072452-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:47/15/0` |
| `20260616-074452-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:15/0/0;c16:59/15/0` |
| `20260616-075116-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:15/0/0;c16:59/15/0` |
| `20260616-075738-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:16/0/0;c16:58/16/0` |
| `20260616-175058-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `ok` | `c1:15/0/0;c4:33/3/0;c8:45/8/0;c16:62/15/0;c32:77/31/0` |
| `20260616-180701-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | coder(4096/1024) | crash | `na` | `na` |
| `20260617-035335-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | coder(4096/1024) | measured | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+nonmonotonic+survivorship@c16+survivorship@c32` | `c1:3/1/0;c4:7/4/0;c8:9/8/0;c16:8/16/0;c32:4/31/0` |
| `20260617-165508-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c4:94/3/0;c8:184/7/0;c16:342/15/0;c32:596/31/0` |
| `20260617-171049-coder` | WeiboAI/VibeThinker-3B | coder(4096/1024) | measured | `ok` | `c1:5/0/0;c4:20/3/0;c8:36/8/0;c16:55/15/0;c32:72/32/0` |
| `20260617-173227-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:341/15/0` |
| `20260617-173847-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:358/15/0` |
| `20260617-174508-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:359/15/0` |
| `20260617-175408-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:342/15/0` |
| `20260617-180030-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:359/15/0` |
| `20260617-180701-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:359/15/0` |
| `20260617-181612-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:338/16/0` |
| `20260617-182232-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:358/15/0` |
| `20260617-182855-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:357/15/0` |
| `20260620-072425-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c4:75/3/0;c8:113/7/0;c16:158/15/0;c32:205/31/0` |
| `20260620-074011-coder` | RedHatAI/Qwen3-Coder-Next-NVFP4 | coder(4096/1024) | measured | `nonmonotonic+survivorship@c32` | `c1:7/0/0;c4:16/3/0;c8:21/7/0;c16:24/15/0;c32:24/31/0` |
| `20260620-120352-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:103/15/0` |
| `20260620-121013-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:103/15/0` |
| `20260620-121632-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:104/16/0` |
| `20260620-123438-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:157/15/0` |
| `20260620-124058-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:155/15/0` |
| `20260620-124721-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:158/15/0` |
| `20260620-130253-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:158/15/0` |
| `20260620-130915-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:154/16/0` |
| `20260620-131535-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:158/15/0` |
| `20260621-073756-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c4:78/4/0;c8:117/7/0;c16:169/16/0;c32:229/32/0` |
| `20260621-075339-coder` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:7/0/0;c4:19/3/0;c8:24/7/0;c16:30/15/0;c32:34/31/0` |
| `20260621-084434-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c16:187/15/0` |
| `20260621-085054-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c16:190/16/0` |
| `20260621-085714-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c16:190/15/0` |
| `20260621-091414-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:34/0/0;c16:187/15/0` |
| `20260621-092032-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:34/1/0;c16:192/16/0` |
| `20260621-092649-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:34/0/0;c16:191/16/0` |
| `20260621-115502-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c4:91/3/0;c8:133/7/0;c16:190/15/0;c32:257/31/0` |
| `20260621-121048-coder` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:9/0/0;c4:21/3/0;c8:29/8/0;c16:35/16/0;c32:40/31/0` |
| `20260622-195737-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:30/0/0;c4:81/3/0;c8:122/7/0;c16:174/15/0;c32:239/31/0` |
| `20260622-201325-coder` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:7/0/0;c4:18/3/0;c8:26/7/0;c16:32/16/0;c32:35/32/0` |
| `20260623-024705-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:198/15/0` |
| `20260623-025324-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:200/15/0` |
| `20260623-025942-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:203/15/0` |
| `20260625-051518-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:8/0/0;c4:26/3/0;c8:48/7/0;c16:77/15/0;c32:116/31/0` |
| `20260625-053128-coder` | unsloth/Qwen3.6-27B-NVFP4 | coder(4096/1024) | measured | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+survivorship@c1+survivorship@c16+survivorship@c32` | `c1:1/1/0;c4:5/3/0;c8:9/7/0;c16:8/15/0;c32:4/31/0` |
| `20260625-080406-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:10/0/0;c16:103/15/0` |
| `20260625-081027-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:103/15/0` |
| `20260625-081656-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:10/0/0;c16:107/15/0` |
| `20260704-192112-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c4:104/3/0;c8:158/7/0;c16:231/15/0;c32:316/31/0` |
| `20260704-193658-coder` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:9/0/0;c4:24/4/0;c8:36/7/0;c16:46/16/0;c32:56/32/0` |
| `20260704-204643-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:230/15/0` |
| `20260704-205306-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | crash | `no_data@c16` | `c1:39/0/0;c16:na` |
| `20260704-211016-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:226/15/0` |
| `20260704-211637-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:229/15/0` |
| `20260704-212259-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:232/15/0` |
| `20260704-215855-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:241/15/0` |
| `20260704-220517-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:246/14/0` |
| `20260704-221137-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:244/15/0` |
| `20260704-224640-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:38/0/0;c4:101/3/0;c8:169/7/0;c16:244/15/0;c32:328/31/0` |
| `20260704-230226-coder` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:9/1/0;c4:23/4/0;c8:39/7/0;c16:50/15/0;c32:59/31/0` |
| `20260709-053426-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:14/0/0;c4:45/3/0;c8:68/7/0;c16:100/15/0;c32:135/32/0` |
| `20260709-055023-coder` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | coder(4096/1024) | measured | `no_data@c1+low_sample@c4+low_sample@c8+low_sample@c16+low_sample@c32+nonmonotonic+survivorship@c32` | `c1:3/0/0;c4:9/4/0;c8:13/7/0;c16:17/15/0;c32:11/32/0` |
| `20260709-070249-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:110/15/0` |
| `20260709-070947-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:113/15/0` |
| `20260709-071646-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:114/15/0` |
| `20260709-074634-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:111/15/0` |
| `20260709-075337-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:114/15/0` |
| `20260709-080035-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:111/15/0` |
| `20260709-084800-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/1/0;c4:54/3/0;c8:79/7/0;c16:112/16/0;c32:152/31/0` |
| `20260709-090400-coder` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | coder(4096/1024) | measured | `no_data@c1+low_sample@c4+low_sample@c8+low_sample@c16+low_sample@c32+survivorship@c32` | `c1:4/1/0;c4:11/3/0;c8:17/8/0;c16:17/16/0;c32:17/32/0` |
| `20260712-004308-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | crash | `no_data@c16` | `c1:39/0/0;c16:na` |
| `20260712-010124-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:38/0/0;c16:241/15/0` |
| `20260712-010744-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:245/15/0` |
| `20260712-011405-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:245/14/0` |
| `20260712-012654-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:242/15/0` |
| `20260712-013315-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:247/15/0` |
| `20260712-013936-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:247/15/0` |
| `20260712-021030-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:240/15/0` |
| `20260712-021652-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:248/15/0` |
| `20260712-022314-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:247/15/0` |
| `20260712-144815-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | crash | `na` | `na` |
| `20260712-153029-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | crash | `no_data@c16` | `c1:54/0/0;c4:118/3/0;c8:201/7/0;c16:na` |
| `20260712-175720-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c1:54/0/0;c16:270/15/0` |
| `20260712-180343-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c1:55/0/0;c16:280/15/0` |
| `20260712-181006-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c1:54/0/0;c16:278/15/0` |
| `20260712-182418-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c32:348/31/0` |
| `20260712-182735-coder` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | coder(4096/1024) | measured | `ok` | `c1:13/1/0;c4:28/4/0;c8:45/8/0;c16:56/16/0;c32:65/32/0` |
| `20260721-164941-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | discard | `na` | `na` |
| `20260721-164944-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | discard | `na` | `na` |
| `20260721-164948-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | discard | `na` | `na` |
| `20260721-165139-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260721-165459-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260721-165817-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260721-170240-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:10/0/0` |
| `20260721-170556-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:10/0/0` |
| `20260721-170926-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:9/0/0` |
| `20260721-171814-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample@c4+nonmonotonic` | `c1:12/0/0;c4:10/3/0` |
| `20260721-172459-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample@c4` | `c1:12/0/0;c4:9/3/0` |
| `20260721-173132-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample@c4` | `c1:12/0/0;c4:9/3/0` |
| `20260721-173859-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample@c4` | `c4:11/3/0` |
| `20260721-174211-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample@c4` | `c4:12/3/0` |
| `20260721-174538-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample@c4` | `c4:12/3/0` |
| `20260808-125135-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:13/0/0` |
| `20260808-125450-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:13/0/0` |
| `20260808-125803-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:13/0/0` |
| `20260808-145317-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260808-145626-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260808-145935-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260808-183119-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:13/0/0` |
| `20260809-162556-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:39/15/0` |
| `20260809-163219-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:42/15/0` |
| `20260809-163845-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:40/15/0` |
| `20260809-164806-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample@c1` | `c1:7/0/0;c16:37/15/0` |
| `20260809-165428-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample@c1` | `c1:7/0/0;c16:37/15/0` |
| `20260809-170056-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample@c1` | `c1:7/0/0;c16:36/15/0` |
| `20260809-170831-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:10/0/0;c16:42/15/0` |
| `20260809-171450-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:10/0/0;c16:40/15/0` |
| `20260809-172113-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:10/0/0;c16:40/15/0` |
| `20260809-172828-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:13/0/0;c16:39/15/0` |
| `20260809-173453-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:40/15/0` |
| `20260809-174112-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:12/0/0;c16:40/15/0` |
| `20260809-174834-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:13/0/0;c16:43/15/0` |
| `20260809-175455-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:13/0/0;c16:42/15/0` |
| `20260809-180126-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:13/0/0;c16:41/15/0` |
| `20260809-180911-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:36/15/0` |
| `20260809-181539-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:11/0/0;c16:35/15/0` |
| `20260809-182207-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:10/0/0;c16:33/15/0` |
| `20260809-183024-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | discard | `survivorship@c32` | `c1:12/0/0;c16:23/15/0;c32:22/31/0` |
| `20260809-184854-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `ok` | `c1:12/0/0;c4:20/3/0;c8:21/7/0;c16:42/15/0` |
| `20260809-190152-coder` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | coder(4096/1024) | discard | `no_data@c1+no_data@c4+no_data@c8+low_sample@c16+nonmonotonic+survivorship@c8+survivorship@c16` | `c1:3/0/0;c4:4/3/0;c8:2/7/0;c16:5/15/0` |
| `20260809-192301-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260809-192612-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260809-192921-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260809-193337-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-193648-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-194006-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-194405-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260809-194721-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260809-195038-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260809-195435-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:13/0/0` |
| `20260809-195744-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-200054-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-200450-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260809-200759-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260809-201107-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:12/0/0` |
| `20260809-201601-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260809-201915-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260809-202228-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260809-202622-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-202938-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260809-203254-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-033033-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-033348-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-033704-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-034126-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260810-034443-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260810-034759-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:15/0/0` |
| `20260810-035159-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-035512-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-035823-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-040218-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-040529-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-040840-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-041234-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-041544-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260810-041852-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `ok` | `c1:14/0/0` |
| `20260815-174443-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:24/0/0;c4:83/3/0;c8:157/7/0;c16:266/15/0;c32:395/32/0` |
| `20260815-183535-coder` | Inferact/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:5/0/0;c4:20/3/0;c8:32/7/0;c16:48/15/0;c32:55/31/0` |
| `20260816-030252-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:170/15/0` |
| `20260816-031322-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:173/15/0` |
| `20260816-032342-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:170/15/0` |
| `20260816-142542-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:170/16/0` |
| `20260816-143609-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:171/15/0` |
| `20260816-144633-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:175/15/0` |
| `20260816-150602-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:187/15/0` |
| `20260816-151632-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/1/0;c16:183/15/0` |
| `20260816-152655-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:191/15/0` |
| `20260816-165725-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:184/15/0` |
| `20260816-170744-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:181/15/0` |
| `20260816-171807-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:179/15/0` |
| `20260816-173728-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:174/15/0` |
| `20260816-174750-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:172/15/0` |
| `20260816-175816-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:173/15/0` |
| `20260816-190354-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:189/15/0` |
| `20260816-191427-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:194/16/0` |
| `20260816-192451-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:192/15/0` |
| `20260816-194425-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:187/16/0` |
| `20260816-195446-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:191/15/0` |
| `20260816-200515-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:188/15/0` |
| `20260816-202448-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:188/15/0` |
| `20260816-203519-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:193/15/0` |
| `20260816-204544-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:190/15/0` |
| `20260816-210549-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/1/0;c16:185/15/0` |
| `20260816-211623-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:192/16/0` |
| `20260816-212644-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/1/0;c16:193/15/0` |
| `20260816-214456-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:187/15/0` |
| `20260816-215519-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:193/15/0` |
| `20260816-220549-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:189/15/0` |
| `20260817-195708-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:12/0/0;c4:46/3/0;c8:72/7/0;c16:113/15/0;c32:136/31/0` |
| `20260817-201312-coder` | Inferact/Qwen3.8-27B-NVFP4 | coder(4096/1024) | discard | `no_data@c1+no_data@c32+low_sample@c4+low_sample@c8+low_sample@c16+survivorship@c16+survivorship@c32` | `c1:3/0/0;c4:9/3/0;c8:12/7/0;c16:10/16/0;c32:2/31/0` |
| `20260818-082342-coder` | Inferact/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:8/1/0;c4:30/4/0;c8:46/8/0;c16:51/15/0;c32:51/32/0` |
| `20260818-100310-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:9/0/0;c4:29/3/0;c8:52/7/0;c16:87/15/0;c32:127/31/0` |
| `20260818-101929-coder` | unsloth/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:7/0/0;c4:22/3/0;c8:40/7/0;c16:57/15/0;c32:75/31/0` |
| `20260818-130426-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:122/15/0` |
| `20260818-131057-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:16/0/0;c16:125/15/0` |
| `20260818-131724-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:16/0/0;c16:122/15/0` |
| `20260818-133106-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:136/15/0` |
| `20260818-133736-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:134/14/0` |
| `20260818-134356-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:139/15/0` |
| `20260818-135818-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | crash | `low_sample@c16+over_roofline@c16+errored@c16` | `c1:20/0/0;c16:16/0/112069` |
| `20260818-141413-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c16:133/15/0` |
| `20260818-142518-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | crash | `low_sample@c16+errored@c16` | `c1:20/0/0;c16:17/0/107589` |
| `20260818-193258-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:135/15/0` |
| `20260818-193926-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:142/15/0` |
| `20260818-194550-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:138/15/0` |
| `20260818-200804-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c16:141/15/0` |
| `20260818-202029-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c16:136/15/0` |
| `20260818-203920-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:138/15/0` |
| `20260818-204548-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:138/15/0` |
| `20260818-205210-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c16:139/15/0` |
| `20260818-210633-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:17/0/0;c4:57/3/0;c8:96/7/0;c16:138/15/0;c32:182/31/0` |
| `20260818-212232-coder` | unsloth/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `ok` | `c1:12/0/0;c4:37/3/0;c8:60/7/0;c16:79/15/0;c32:96/31/0` |
| `20260819-191404-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:19/0/0;c16:134/15/0` |
| `20260819-192032-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:18/0/0;c16:141/15/0` |

