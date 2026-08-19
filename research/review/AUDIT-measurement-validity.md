# Audit — measurement validity of the published record

Forensic pass over every benchmark row this project has published, against
[`docs/validity-contract.md`](../../docs/validity-contract.md) v1 §3. Issue #1 §1 asks the
question; this answers it with the evidence on disk.

- **Tool:** `scripts/audit_results.py` (read-only; imports the rules from `scripts/lib/validity.py`,
  which per contract §1 is the only implementation).
- **Population:** 315 rows in 15 `results.tsv` journals. The review issue quotes 313; the two extra
  are `20260819-191404-chat` and `20260819-192032-chat`, added to
  `unsloth/Qwen3.8-27B-NVFP4` after the issue was written. Neither changes any conclusion below.
- **Evidence:** 693 retained `level_c*.json` bundles under `results/*/*/*/data/`.
- **Reproduce:** `uv run scripts/audit_results.py --repo-root <checkout> --mem-bw 273`
  (see §7 for why `--mem-bw` has to be passed by hand today).
- **Not done:** no docker, no serve, no GuideLLM, no lm-eval, no GPU. Nothing was written to any
  `results.tsv`; status adjudication is the orchestrator's per contract §7.

---

## 1. Headline

| verdict | rows | share |
|---|---:|---:|
| `ok` — all invariants pass | **124** | 39% |
| `suspect` — one or more suspect verdicts | **169** | 54% |
| `void` — one or more fatal verdicts | **16** | 5% |
| unauditable — bundle gone, verdict unknowable forever | **6** | 2% |
| **total** | **315** | |

**Two out of every five published rows clear the contract.** The dominant failure is a single
verdict — `low_sample` on 170 rows — and §6 shows that verdict is miscalibrated rather than
diagnostic. Reading past it, the record is in better shape than the raw split suggests: the fatal
count is 16, and the numbers those 16 rows carry are almost entirely coder-shape characterisation
figures, not the `chat` c16 medians the project actually tunes against.

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

All six are already `crash` or `discard`, so nothing citable is lost. **2% is the permanent
audit ceiling on this record.** The `results.tsv` schema change in contract §2 — carrying
`req_counts` in the committed journal — is what stops that number growing.

---

## 2. Promotion risk — does any `_final` rest on an invalid row?

**Yes. Two promoted configs quote throughput gains in their own `# Result:` header that are
computed entirely from rows the contract calls `void`.** Both are coder-shape claims. Named:

### 2a. `runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/VLLM-23-RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B_NVFP4_final.sh`

> `# Result: ... coder c16=53.2/c32=22.2 (+43% vs baseline).`

| operand | row | bundle counts (ok/inc/err) | verdict |
|---|---|---|---|
| 53.23 / 22.23 (candidate) | `20260617-035335-coder` | `c1:3/1/0; c4:7/4/0; c8:9/8/0; c16:8/16/0; c32:4/31/0` | **`no_data+nonmonotonic`** |
| 37.26 (baseline) | `20260615-180752-coder` | `c1:3/0/0; c4:5/3/0; c8:6/7/0; c16:6/15/0; c32:1/31/0` | **`no_data+nonmonotonic`** |

53.23 / 37.26 = **+42.9%**, matching the header exactly. The c32 figure of 22.23 is the mean of
**four** completed requests while 31 were discarded; the baseline c32 of 9.99 is the mean of **one**.
Both curves invert (`c8 65.39 → c16 53.23 → c32 22.23`). Both rows are still `status=measured`.

### 2b. `runbooks/nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4/VLLM-24-nvidia_NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B_NVFP4_final.sh`

> `# Result: ... coder c32 70.7->114.1 (+61%)`

| operand | row | bundle counts | verdict |
|---|---|---|---|
| 114.06 (candidate) | `20260709-090400-coder` | `c1:4/1/0; c4:11/3/0; c8:17/8/0; c16:17/16/0; c32:17/32/0` | **`no_data`** |
| 70.69 (baseline) | `20260709-055023-coder` | `c1:3/0/0; c4:9/4/0; c8:13/7/0; c16:17/15/0; c32:11/32/0` | **`no_data+nonmonotonic`** |

114.06 / 70.69 = **+61.4%**, matching. Both c32 means discard roughly two-thirds of the requests
they started. Both rows are `status=measured`.

### 2c. The tuned objective itself is sound

The decision every campaign actually made — median `chat` c16 across an N=3 bracket — holds up.
Checking the c16 level of every chat row supporting every `_final`:

- **14 of 15** finals have ≥3 chat-c16 levels with ≥20 successful requests and no fatal verdict on
  that level — the N=3 bracket the charter requires. Counts run 57–392 successful, far above any
  threshold under discussion.
- **3 of those 14** also carry a chat row whose c16 is `no_data`:
  `VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` (`20260614-095503-chat`),
  `VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` (`20260712-004308-chat`), and
  `VLLM-25-unsloth_Qwen3.6-35B-A3B-NVFP4-Fast_final.sh` (`20260712-153029-chat`). All three are GB10
  wedges: the journal records the sentinel `hang` in `tps_c16` and GuideLLM never wrote the level
  file. None of the three promotions depended on them — each has 3, 7 and 3 valid c16 rows
  respectively in the same bracket.
- **1 of 15** — `VLLM-23-RedHatAI_Qwen3-Coder-Next_NVFP4_final.sh` — rests on a **single** valid
  chat-c16 row (`20260620-072425-chat`, `c16:158/15/0`). It was a baseline-wins campaign, so no N=3
  bracket was ever run on the promoted config. The number is valid; the charter's N=3 rule was not
  applied to it.

**So: no promotion's speed ranking is refuted by this audit. Two promotions' published gain claims
are.** The distinction matters — the configs are probably still the right ones to serve; the
percentages printed on them are not citable.

### 2d. What contract §5 would have done

§5 says `promote.sh` refuses a config whose supporting rows are `void`/`suspect`. Applied literally
to history, **12 of 15 finals would have been blocked**; only `VLLM-22-RedHatAI_Qwen3-8B_NVFP4`,
`VLLM-23-RedHatAI_Qwen3-8B_NVFP4` and `VLLM-23-nvidia_Qwen3-Next-80B-A3B-Thinking_NVFP4` pass
clean. Nine of those twelve are blocked solely by `low_sample` on c1 — see §6. **The §5 rule should
gate on the rows a promotion actually cites, at the levels it cites, not on every row that shares a
runbook path.**

**Provenance gap this audit had to work around:** nothing machine-readable links a `_final.sh` to
its supporting rows. `status` is *never* `keep` — the vocabulary in 315 rows is `measured` (295),
`crash` (12), `discard` (6). Every keep/discard decision lives in prose in a logbook or a runbook
header. This tool reconstructs the link by regex-matching `promoted from <path>.sh` in the final's
header and matching the `script` column. **§5's promote-time gate cannot be implemented until a
promotion records its supporting `run_id`s.**

---

## 3. The three known defects, independently rediscovered

Required cross-check. All three fall out of the bundles without being looked for.

| issue #1 defect | run_id | verdict | evidence |
|---|---|---|---|
| c32 = 256.19 from **2** completed requests | `20260817-201312-coder` | **`no_data`** → void | `c1:3/0/0; c4:9/3/0; c8:12/7/0; c16:10/16/0; c32:2/31/0` |
| `tps_c16` = **449,358** from a dead endpoint | `20260818-135818-chat` | **`errored+low_sample+over_roofline`** → void | `c1:20/0/0; c16:16/0/112069` |
| FF711 non-monotonic coder curve | `20260809-190152-coder` | **`no_data+nonmonotonic`** → void | `c1:3/0/0; c4:4/3/0; c8:2/7/0; c16:5/15/0`; curve `27.57 → 121.23 → 47.72 → 56.42` |

Two caveats on the 449,358 row, both contract issues (§7):

1. `over_roofline` fires **only** when `--mem-bw 273` is supplied on the command line.
   `gpu.mem_bw_gbs` does not exist in `results/gb10-1988a9714b4e/node_profile.json`, so by §4 the
   check is skipped and the contract's own worked example does not fire on the default run. The row
   is still caught, by `errored` — but by the weaker of the two rules.
2. The **sibling** MTP n=4 crash, `20260818-142518-chat` (`tps_c16` = **1,992.87**, `c16:17/0/107589`),
   is **not** caught by `over_roofline` even with 273 GB/s supplied. §4's `AHL_MIN_MODEL_GB` fallback
   of 1.0 GB/token puts the c16 ceiling at 8,736 tok/s. With the real active weight bytes of a 27B
   NVFP4 model (~13.5 GB/token) the ceiling is ~647 tok/s and it is refuted immediately.

---

## 4. Breakdowns

### By shape — the coder shape has never produced a clean row

| shape | ok | suspect | void | unauditable | n |
|---|---:|---:|---:|---:|---:|
| `chat(512/256)` | 124 | 156 | 7 | 5 | 292 |
| `coder(4096/1024)` | **0** | 13 | 9 | 1 | **23** |

**Not one of the 23 coder rows in the project's history passes the invariants.** 39% of them are
fatal. This is arithmetic, not bad luck — see §5a.

### By campaign

| campaign | ok | suspect | void | unaud | n |
|---|---:|---:|---:|---:|---:|
| DavidAU/Qwen3.6-27B-FF711 (llama.cpp) | 0 | 20 | 1 | 0 | 21 |
| Inferact/Qwen3.8-27B-NVFP4 | 18 | 16 | 1 | 0 | 35 |
| RedHatAI/NVIDIA-Nemotron-3-Super-120B | 0 | 26 | 2 | 1 | 29 |
| RedHatAI/Qwen3-8B-NVFP4 | 27 | 1 | 2 | 1 | 31 |
| RedHatAI/Qwen3-Coder-Next-NVFP4 | 7 | 4 | 0 | 0 | 11 |
| RedHatAI/Qwen3.6-35B-A3B-NVFP4 | 36 | 2 | 4 | 0 | 42 |
| RedHatAI/gemma-4-31B-it-NVFP4 | 0 | 16 | 1 | 0 | 17 |
| WeiboAI/VibeThinker-3B | 10 | 1 | 0 | 0 | 11 |
| antirez/DeepSeek-V4-Flash (ds4) | 0 | 55 | 0 | 3 | 58 |
| nvidia/Nemotron-Labs-3-Puzzle-75B | 6 | 2 | 2 | 0 | 10 |
| nvidia/Qwen3-Next-80B-Instruct | 8 | 2 | 0 | 0 | 10 |
| nvidia/Qwen3-Next-80B-Thinking | 4 | 1 | 0 | 0 | 5 |
| unsloth/Qwen3.6-27B-NVFP4 | 0 | 4 | 1 | 0 | 5 |
| unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | 4 | 1 | 1 | 1 | 7 |
| unsloth/Qwen3.8-27B-NVFP4 | 4 | 18 | 1 | 0 | 23 |

The four campaigns with **zero** clean rows — FF711, Nemotron-3-Super-120B, gemma-4-31B, ds4 — are
exactly the four slowest models on the node. Their c1 stages cannot reach 20 requests in 180 s.
That is the whole explanation; it is not a quality difference between campaigns.

### By status

| journal status | ok | suspect | void | unaud | n |
|---|---:|---:|---:|---:|---:|
| `measured` | 124 | 167 | 6 | 0 | 297 |
| `crash` | 0 | 1 | 8 | 3 | 12 |
| `discard` | 0 | 1 | 2 | 3 | 6 |
| `keep` | — | — | — | — | **0** |

**Zero rows are marked `keep`.** The brief asks how many `keep` rows fail the invariants; the answer
is that the status column has never been used to record an adjudication. `measured` covers 94% of
the record, and contract §6's claim that `measured` will come to mean "the invariants passed" is a
change from "a row exists", which is what it means today.

**Six `measured` rows are fatal and remain uncorrected in the journal.** Named, so the orchestrator
can adjudicate them (contract §7):

| run_id | campaign | verdict | worst level |
|---|---|---|---|
| `20260615-180752-coder` | RedHatAI/Nemotron-3-Super-120B | `no_data+nonmonotonic` | c32: 1 ok / 31 incomplete |
| `20260617-035335-coder` | RedHatAI/Nemotron-3-Super-120B | `no_data+nonmonotonic` | c32: 4 ok / 31 incomplete |
| `20260614-211454-coder` | RedHatAI/gemma-4-31B-it | `no_data+nonmonotonic` | c32: 1 ok / 31 incomplete |
| `20260709-055023-coder` | nvidia/Puzzle-75B | `no_data+nonmonotonic` | c1: 3 ok |
| `20260709-090400-coder` | nvidia/Puzzle-75B | `no_data` | c1: 4 ok |
| `20260625-053128-coder` | unsloth/Qwen3.6-27B | `no_data` | c1: **1** ok |

All six are coder rows. Four of them are cited in a promoted `_final.sh` or a logbook comparison.

---

## 5. Defects nobody was looking for

### 5a. The coder shape has never once produced a valid c1 sample — and it is arithmetically impossible that it could

At concurrency 1 the number of requests a stage can complete is
`max_seconds × tok/s ÷ mean_output_tokens`. For `coder(4096/1024)` at `MAX_SECONDS=180`, reaching
20 requests requires **113.8 tok/s at c1**. The fastest c1 ever recorded on this node, in any shape,
on any model, is **80.28** (`20260712-182735-coder`, 35B-A3B-Fast). The threshold has never been
reachable and never will be on this hardware.

The record confirms it exactly: **22 of 22 coder c1 levels are below 20 successful.** Distribution:
min 1, p25 3, median 7, max 13. Raising `MAX_SECONDS` to 600 helps but does not fix it — the bar
drops to 34.1 tok/s and 4 of 4 rows at 600 s are still starved.

| shape | max_s | tok/s needed for n=20 at c1 | levels starved |
|---|---:|---:|---|
| chat | 180 | 28.4 | 139 / 249 |
| chat | 300 | 17.1 | 13 / 30 |
| chat | 600 | 8.5 | 0 / 1 |
| coder | 180 | **113.8** | **18 / 18** |
| coder | 600 | 34.1 | **4 / 4** |

This is a design constraint of the shape, not a harness bug — but it means the coder c1 column has
never carried a defensible number, in any campaign, and several `_final.sh` headers quote it.

### 5b. GuideLLM's `successful.mean` is survivorship-biased, and the bias grows monotonically with concurrency

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
faster half. **The contract has no rule for this** — `incomplete` appears in `req_counts` but in no
verdict. In 20 of 690 run levels — spread over 11 rows — `incomplete ≥ successful`; 8 of those rows are `status=measured`.

This also explains the coder curve inversions the project has been reading as engine behaviour:
throughput does not actually fall between c8 and c32, the *estimator* stops being able to keep up.
It is the mechanism behind issue #1's "non-monotonic curve" symptom, and it means a low `MAX_SECONDS`
does not merely add noise — it adds **directional bias**.

**Proposed verdict token: `survivorship` (suspect) when any run level has `incomplete ≥ successful`.**
Applied to the record it flags 11 of 309 auditable rows (20 of 690 levels) — precise, cheap, and it catches exactly the
rows where the reported mean is structurally untrustworthy.

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

Every one is `status=measured` and the journal's `max_s` column records each correctly. Nothing ever
compared them. The campaign's headline improvement is a 300 s number divided by a 600 s number, and
the promoted config's published sweep is a third, 180 s measurement. Given §5b, longer stages are not
just better-sampled but *less biased*, so these are not interchangeable.

Good news alongside it: **`max_s` in the journal matches the bundle's `args.max_seconds` on all 309
auditable rows — zero mismatches.** The knob was recorded honestly the whole time; nothing read it.

### 5d. `tps_c*` carries an undocumented non-numeric sentinel

The throughput columns contain three kinds of value: numbers, `na` (868 cells), and **`hang`
(13 cells)**. `hang` appears in no schema, in no doc, and in contract §2 — which says values are
never empty and to use `na`. Any consumer doing `float()` on a throughput column breaks or silently
drops those rows. All 13 sit on `crash` rows where the GB10 wedge killed GuideLLM before it wrote
the level file, which is why 7 rows publish a `tps_c16` cell with no `level_c16.json` behind it.
Either document `hang` in the schema or fold it into `na` and let `status=crash` + `validity` carry
the meaning.

### 5e. Reproducibility fundamentals are clean — say so

Across all 690 audited levels: **`random_seed` is 42 on every one**, `guidellm_version` is `0.6.0`
on every one, and each shape's synthetic `--data` spec is byte-identical across three years of
campaigns and four vLLM minor versions. There is exactly one prompt spec per shape. Whatever else
this audit found, the harness has never silently changed its stimulus.

### 5f. Roofline caveat: speculative decoding legitimately breaks the §4 bound

FF711 `20260809-190152-coder` measured c4 = 121.23 tok/s on a model AGENTS.md documents at
21.18 GB/token. The §4 bound with the true bytes and `SAFETY=2.0` is `2 × 4 × 273 / 21.18 = 103.1` —
so a **legitimate** MTP run would trip `over_roofline` as a false positive. With MTP's measured
accepted length of 2.69 the physical ceiling is ~138.7 and 121.23 is fine. `SAFETY` is doing the job
of a speculation factor; it should be `1 + num_speculative_tokens` (or a documented per-config
value), not a flat 2.0, or every well-tuned MTP config on this box becomes a false alarm the moment
`gpu.mem_bw_gbs` lands in the node profile.

---

## 6. `low_sample` calibration (requested by the orchestrator)

### 6a. Distribution of `successful` per level (all 693 retained bundles)

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

The flat threshold of 20 sits **above the median** of chat c1 (18) and **above the maximum** of
coder c1 (13). It is not detecting an anomaly; it is drawing a line through the middle of the
normal operating distribution.

Counted per level rather than per row: **174 of 302 c1 levels (58%) trip `low_sample`**, against
c4 18/52, c8 8/46, c16 **10/253 (4%)**, c32 7/44. Of the 166 rows whose verdict is *exactly*
`low_sample`, **c1 is the sole offending level in 158**. (This is A1's finding independently; small
count differences come from level-set determination — this tool treats a level as run if the journal
published a cell for it **or** a bundle file exists, which picks up the `hang` rows.)

### 6b. Flag rate by candidate rule, and whether the §0 defects survive

| rule | ok | suspect | void | 3 defects still caught? |
|---|---:|---:|---:|---|
| flat 20 (current) | 40% | **55%** | 4% | yes |
| flat 10 | 82% | 12% | 4% | yes |
| per-shape (chat 20 / coder 8) | 42% | **53%** | 4% | yes |
| `min(20, 4×level)` (A1) | **92%** | 2% | 4% | yes |
| `max(5, min(20, 2×level))` | 93% | 1% | 4% | yes |
| `min(20, 4×level)`, halved for coder | 92% | 2% | 4% | yes |

**Every candidate keeps all three §0 defects.** That is not luck — none of the three is detected by
`low_sample` in the first place. The 2-request coder row and the FF711 row are caught by `no_data`
(`AHL_MIN_DATA=5`, which stays flat), and the 449,358 row by `errored` and `over_roofline`.
**`AHL_MIN_SUCCESSFUL` can be recalibrated without weakening a single demonstrated detection.**
`AHL_MIN_DATA` is the load-bearing threshold and must not move.

Note the per-shape option barely helps (53% vs 55%). The problem is not the coder shape — it is
chat c1, which appears in 280 of 309 auditable rows.

### 6c. Does a starved level actually measure worse? No.

The decisive test, which nobody has run: take every replicate bracket in the journal
(same journal, script, shape, `config_hash`, N≥3) and compute the coefficient of variation of the
reported tok/s at each level, split by whether the level was starved.

| level | brackets | n < 20 → median CV | n ≥ 20 → median CV |
|---|---:|---:|---:|
| c1 | 77 | **1.18%** | 0.35% |
| c16 | 65 | (k=1, degenerate) | 1.23% |

Banded across all levels:

| successful per level | brackets | median CV | p90 CV |
|---|---:|---:|---:|
| n < 10 | 8 | **0.39%** | 1.87% |
| 10 ≤ n < 20 | 40 | 1.42% | 4.60% |
| 20 ≤ n < 50 | 43 | 0.56% | 2.57% |
| n ≥ 50 | 53 | 1.10% | 2.59% |

**There is no monotone relationship between request count and reproducibility.** The least-sampled
band is the *most* reproducible. A c1 level with 8–19 completed requests reproduces to ~1.2%, well
inside the ±3% KEEP rule and an order of magnitude inside the ~10% cross-session drift AGENTS.md
already documents for this box.

The reason is that requests are the wrong unit. At c1 a single request is 256 sequential decode
steps, so a level with 8 requests averages ~2,048 token-generation events. The precision of the
estimator scales with **tokens generated**, not requests completed — which is why 8 coder requests
(8,192 tokens) beat 20 chat requests (5,120 tokens) despite looking four times worse by request count.

### 6d. Recommendation

Replace the flat request threshold with a **token-budget rule plus a batch-coverage floor**, and add
the survivorship rule from §5b:

```
no_data      : successful < 5                                    (UNCHANGED — do not move)
low_sample   : successful × mean_output_tokens < 2048            (precision arm)
               OR successful < max(5, min(20, 4 × level))        (coverage arm)
survivorship : incomplete >= successful                          (NEW, suspect — see §5b)
```

Measured on the record: **90% ok / 4% suspect / 4% void**, all three §0 defects still caught. The
precision arm is calibrated at 2,048 tokens because that is where §6c's dispersion data stops
improving; 4,096 jumps the suspect rate to 40% and buys no measurable precision. The coverage arm
exists for a different reason than precision — at c32 you need enough requests to have actually
filled the batch, and `4 × level` capped at 20 expresses that directly.

If a single number is wanted instead, **`max(5, min(20, 4 × level))` alone** gives 92% / 2% / 4%
and is the right shape of rule: it asks each level for four requests per concurrency slot, which is
the same question at c1 and c32. It just loses the survivorship arm, which is the finding that
actually explains the coder curves.

**The one thing not to do is keep flat 20.** A verdict that fires on 55% of the journal, whose
median target is 18 against a threshold of 20, and which §6c shows is uncorrelated with measurement
error, will be routinely overridden — and the next `no_data` will be overridden along with it.

---

## 7. Contract issues found (implemented as written, per §0)

1. **§4's worked example does not fire.** `gpu.mem_bw_gbs` is absent from
   `results/gb10-1988a9714b4e/node_profile.json`, so §4 skips the roofline and the 449,358 row —
   the contract's own illustration of `over_roofline` — is caught only by `errored`. The audit had
   to be run with an explicit `--mem-bw 273` (the value §4 itself names) to demonstrate the rule.
   The probe change is a hard prerequisite, not a nice-to-have.
2. **`AHL_MIN_MODEL_GB = 1.0` is too loose to refute anything real.** It puts the c16 ceiling at
   8,736 tok/s, so the 1,992.87 tok/s dead-endpoint row passes. The active-weight bytes are
   derivable from the model card for every campaign on record; the fallback should be the exception.
3. **`SAFETY = 2.0` collides with speculative decoding** (§5f). Measured MTP accepted lengths reach
   2.69 on this node, so a legitimate MTP config can exceed a 2.0-safety bound built from true
   bytes/token. Tie `SAFETY` to `1 + num_speculative_tokens`.
4. **§5's promote-time gate is not implementable today.** It requires knowing a promotion's
   supporting rows; nothing records them (§2d). Either `promote.sh` writes the `run_id`s into the
   `_final.sh` header, or the gate stays advisory.
5. **§3's `nonmonotonic` is the right call and the contract's own note undersells it.** The rule
   caught 7 rows, all real inversions, no false positives — and §5b now supplies the mechanism
   (survivorship bias), which makes it more informative than "noise on a bandwidth-bound box".
6. **§2's `na` convention is already violated by `hang`** (§5d). Decide which it is before the
   schema is frozen.
7. **Objection to a verdict the contract produces:** the contract makes `low_sample` a property of a
   *row*, so a row is suspect if any level is starved. In practice a campaign cites one level (chat
   c16) and characterises the rest. Per-row severity therefore condemns the objective for a defect
   in a level nobody read — the mechanism behind §2d's "12 of 15 finals blocked". `validity` already
   carries the tokens; it should carry the **level** too (`low_sample@c1`), so consumers can gate on
   the level they cite.

---

## Appendix A — per-row verdicts

315 rows, ordered by `run_id`. `req_counts` is `successful/incomplete/errored` per run level;
`na` for a level that was attempted but left no bundle. Generated by
`uv run scripts/audit_results.py --repo-root <checkout> --mem-bw 273 --format markdown`.

| run_id | model | shape | status | verdict | req_counts (ok/inc/err) |
|---|---|---|---|---|---|
| `20260613-105041` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | crash | `na` | `na` |
| `20260613-122100-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c4:109/3/0;c8:201/7/0;c16:331/14/0;c32:481/31/0` |
| `20260613-123642-coder` | RedHatAI/Qwen3-8B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:7/0/0;c4:18/4/0;c8:27/7/0;c16:32/15/0;c32:30/32/0` |
| `20260613-130852-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:27/0/0;c16:333/16/0` |
| `20260613-131512-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:349/15/0` |
| `20260613-132132-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c16:351/16/0` |
| `20260613-134328-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | crash | `no_data` | `c1:29/0/0;c16:na` |
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
| `20260613-213556-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | crash | `no_data` | `c1:29/0/0;c16:na` |
| `20260614-073625-chat` | RedHatAI/Qwen3-8B-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c4:114/3/0;c8:215/7/0;c16:387/15/0;c32:652/31/0` |
| `20260614-085507-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c4:106/3/0;c8:161/7/0;c16:233/15/0;c32:315/31/0` |
| `20260614-094220-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:230/15/0` |
| `20260614-094840-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:234/15/0` |
| `20260614-095503-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | crash | `no_data` | `c1:39/0/0;c16:na` |
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
| `20260614-205253-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c4:28/3/0;c8:49/7/0;c16:76/16/0;c32:100/31/0` |
| `20260614-211454-coder` | RedHatAI/gemma-4-31B-it-NVFP4 | coder(4096/1024) | measured | `no_data+nonmonotonic` | `c1:2/0/0;c4:5/3/0;c8:7/8/0;c16:6/15/0;c32:1/31/0` |
| `20260614-213825-coder` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | coder(4096/1024) | crash | `no_data` | `c1:9/1/0;c4:25/3/0;c8:36/7/0;c16:na` |
| `20260614-232113-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:73/15/0` |
| `20260614-232748-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:73/16/0` |
| `20260614-233424-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:73/16/0` |
| `20260614-234718-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:89/15/0` |
| `20260614-235353-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:91/16/0` |
| `20260615-000026-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:96/15/0` |
| `20260615-002424-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:71/15/0` |
| `20260615-003104-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:77/15/0` |
| `20260615-003745-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:77/15/0` |
| `20260615-005512-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:73/15/0` |
| `20260615-010146-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:74/16/0` |
| `20260615-010820-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:73/15/0` |
| `20260615-012003-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:59/15/0` |
| `20260615-012638-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:61/15/0` |
| `20260615-013315-chat` | RedHatAI/gemma-4-31B-it-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c16:60/16/0` |
| `20260615-175157-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c4:28/3/0;c8:38/7/0;c16:49/15/0;c32:63/31/0` |
| `20260615-180752-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | coder(4096/1024) | measured | `no_data+nonmonotonic` | `c1:3/0/0;c4:5/3/0;c8:6/7/0;c16:6/15/0;c32:1/31/0` |
| `20260616-031158-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:51/14/0` |
| `20260616-031839-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:48/15/0` |
| `20260616-032523-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:49/15/0` |
| `20260616-034532-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:15/0/0;c16:57/15/0` |
| `20260616-035153-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:15/0/0;c16:58/15/0` |
| `20260616-035814-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:16/0/0;c16:58/15/0` |
| `20260616-041612-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:47/15/0` |
| `20260616-042232-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:51/15/0` |
| `20260616-042857-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:50/15/0` |
| `20260616-044718-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:49/15/0` |
| `20260616-045342-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:50/15/0` |
| `20260616-050004-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:50/15/0` |
| `20260616-051829-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:48/15/0` |
| `20260616-052452-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:50/15/0` |
| `20260616-053112-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:51/15/0` |
| `20260616-063656-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:27/15/0` |
| `20260616-064321-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:26/15/0` |
| `20260616-064943-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:27/15/0` |
| `20260616-071209-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:50/15/0` |
| `20260616-071831-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:47/16/0` |
| `20260616-072452-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:47/15/0` |
| `20260616-074452-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:15/0/0;c16:59/15/0` |
| `20260616-075116-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:15/0/0;c16:59/15/0` |
| `20260616-075738-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:16/0/0;c16:58/16/0` |
| `20260616-175058-chat` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:15/0/0;c4:33/3/0;c8:45/8/0;c16:62/15/0;c32:77/31/0` |
| `20260616-180701-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | coder(4096/1024) | crash | `na` | `na` |
| `20260617-035335-coder` | RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | coder(4096/1024) | measured | `no_data+nonmonotonic` | `c1:3/1/0;c4:7/4/0;c8:9/8/0;c16:8/16/0;c32:4/31/0` |
| `20260617-165508-chat` | WeiboAI/VibeThinker-3B | chat(512/256) | measured | `ok` | `c1:22/0/0;c4:94/3/0;c8:184/7/0;c16:342/15/0;c32:596/31/0` |
| `20260617-171049-coder` | WeiboAI/VibeThinker-3B | coder(4096/1024) | measured | `low_sample` | `c1:5/0/0;c4:20/3/0;c8:36/8/0;c16:55/15/0;c32:72/32/0` |
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
| `20260620-074011-coder` | RedHatAI/Qwen3-Coder-Next-NVFP4 | coder(4096/1024) | measured | `low_sample+nonmonotonic` | `c1:7/0/0;c4:16/3/0;c8:21/7/0;c16:24/15/0;c32:24/31/0` |
| `20260620-120352-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:103/15/0` |
| `20260620-121013-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:103/15/0` |
| `20260620-121632-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:104/16/0` |
| `20260620-123438-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:157/15/0` |
| `20260620-124058-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:155/15/0` |
| `20260620-124721-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:158/15/0` |
| `20260620-130253-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:158/15/0` |
| `20260620-130915-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:154/16/0` |
| `20260620-131535-chat` | RedHatAI/Qwen3-Coder-Next-NVFP4 | chat(512/256) | measured | `ok` | `c1:28/0/0;c16:158/15/0` |
| `20260621-073756-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:29/0/0;c4:78/4/0;c8:117/7/0;c16:169/16/0;c32:229/32/0` |
| `20260621-075339-coder` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:7/0/0;c4:19/3/0;c8:24/7/0;c16:30/15/0;c32:34/31/0` |
| `20260621-084434-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c16:187/15/0` |
| `20260621-085054-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c16:190/16/0` |
| `20260621-085714-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c16:190/15/0` |
| `20260621-091414-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:34/0/0;c16:187/15/0` |
| `20260621-092032-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:34/1/0;c16:192/16/0` |
| `20260621-092649-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:34/0/0;c16:191/16/0` |
| `20260621-115502-chat` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | chat(512/256) | measured | `ok` | `c1:36/0/0;c4:91/3/0;c8:133/7/0;c16:190/15/0;c32:257/31/0` |
| `20260621-121048-coder` | nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:9/0/0;c4:21/3/0;c8:29/8/0;c16:35/16/0;c32:40/31/0` |
| `20260622-195737-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:30/0/0;c4:81/3/0;c8:122/7/0;c16:174/15/0;c32:239/31/0` |
| `20260622-201325-coder` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:7/0/0;c4:18/3/0;c8:26/7/0;c16:32/16/0;c32:35/32/0` |
| `20260623-024705-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:198/15/0` |
| `20260623-025324-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:200/15/0` |
| `20260623-025942-chat` | nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4 | chat(512/256) | measured | `ok` | `c1:40/0/0;c16:203/15/0` |
| `20260625-051518-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:8/0/0;c4:26/3/0;c8:48/7/0;c16:77/15/0;c32:116/31/0` |
| `20260625-053128-coder` | unsloth/Qwen3.6-27B-NVFP4 | coder(4096/1024) | measured | `no_data` | `c1:1/1/0;c4:5/3/0;c8:9/7/0;c16:8/15/0;c32:4/31/0` |
| `20260625-080406-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:10/0/0;c16:103/15/0` |
| `20260625-081027-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:103/15/0` |
| `20260625-081656-chat` | unsloth/Qwen3.6-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:10/0/0;c16:107/15/0` |
| `20260704-192112-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c4:104/3/0;c8:158/7/0;c16:231/15/0;c32:316/31/0` |
| `20260704-193658-coder` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:9/0/0;c4:24/4/0;c8:36/7/0;c16:46/16/0;c32:56/32/0` |
| `20260704-204643-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:230/15/0` |
| `20260704-205306-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | crash | `no_data` | `c1:39/0/0;c16:na` |
| `20260704-211016-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:226/15/0` |
| `20260704-211637-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:229/15/0` |
| `20260704-212259-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:232/15/0` |
| `20260704-215855-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:241/15/0` |
| `20260704-220517-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:246/14/0` |
| `20260704-221137-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:39/0/0;c16:244/15/0` |
| `20260704-224640-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | measured | `ok` | `c1:38/0/0;c4:101/3/0;c8:169/7/0;c16:244/15/0;c32:328/31/0` |
| `20260704-230226-coder` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:9/1/0;c4:23/4/0;c8:39/7/0;c16:50/15/0;c32:59/31/0` |
| `20260709-053426-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:14/0/0;c4:45/3/0;c8:68/7/0;c16:100/15/0;c32:135/32/0` |
| `20260709-055023-coder` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | coder(4096/1024) | measured | `no_data+nonmonotonic` | `c1:3/0/0;c4:9/4/0;c8:13/7/0;c16:17/15/0;c32:11/32/0` |
| `20260709-070249-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:110/15/0` |
| `20260709-070947-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:113/15/0` |
| `20260709-071646-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:114/15/0` |
| `20260709-074634-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:111/15/0` |
| `20260709-075337-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:114/15/0` |
| `20260709-080035-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:111/15/0` |
| `20260709-084800-chat` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/1/0;c4:54/3/0;c8:79/7/0;c16:112/16/0;c32:152/31/0` |
| `20260709-090400-coder` | nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 | coder(4096/1024) | measured | `no_data` | `c1:4/1/0;c4:11/3/0;c8:17/8/0;c16:17/16/0;c32:17/32/0` |
| `20260712-004308-chat` | RedHatAI/Qwen3.6-35B-A3B-NVFP4 | chat(512/256) | crash | `no_data` | `c1:39/0/0;c16:na` |
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
| `20260712-153029-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | crash | `no_data` | `c1:54/0/0;c4:118/3/0;c8:201/7/0;c16:na` |
| `20260712-175720-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c1:54/0/0;c16:270/15/0` |
| `20260712-180343-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c1:55/0/0;c16:280/15/0` |
| `20260712-181006-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c1:54/0/0;c16:278/15/0` |
| `20260712-182418-chat` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | chat(512/256) | measured | `ok` | `c32:348/31/0` |
| `20260712-182735-coder` | unsloth/Qwen3.6-35B-A3B-NVFP4-Fast | coder(4096/1024) | measured | `low_sample` | `c1:13/1/0;c4:28/4/0;c8:45/8/0;c16:56/16/0;c32:65/32/0` |
| `20260721-164941-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | discard | `na` | `na` |
| `20260721-164944-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | discard | `na` | `na` |
| `20260721-164948-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | discard | `na` | `na` |
| `20260721-165139-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260721-165459-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260721-165817-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260721-170240-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:10/0/0` |
| `20260721-170556-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:10/0/0` |
| `20260721-170926-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:9/0/0` |
| `20260721-171814-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample+nonmonotonic` | `c1:12/0/0;c4:10/3/0` |
| `20260721-172459-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c4:9/3/0` |
| `20260721-173132-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c4:9/3/0` |
| `20260721-173859-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c4:11/3/0` |
| `20260721-174211-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c4:12/3/0` |
| `20260721-174538-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c4:12/3/0` |
| `20260808-125135-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:13/0/0` |
| `20260808-125450-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:13/0/0` |
| `20260808-125803-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:13/0/0` |
| `20260808-145317-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260808-145626-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260808-145935-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260808-183119-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:13/0/0` |
| `20260809-162556-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:39/15/0` |
| `20260809-163219-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:42/15/0` |
| `20260809-163845-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:40/15/0` |
| `20260809-164806-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:7/0/0;c16:37/15/0` |
| `20260809-165428-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:7/0/0;c16:37/15/0` |
| `20260809-170056-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:7/0/0;c16:36/15/0` |
| `20260809-170831-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:10/0/0;c16:42/15/0` |
| `20260809-171450-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:10/0/0;c16:40/15/0` |
| `20260809-172113-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:10/0/0;c16:40/15/0` |
| `20260809-172828-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:13/0/0;c16:39/15/0` |
| `20260809-173453-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:40/15/0` |
| `20260809-174112-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c16:40/15/0` |
| `20260809-174834-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:13/0/0;c16:43/15/0` |
| `20260809-175455-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:13/0/0;c16:42/15/0` |
| `20260809-180126-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:13/0/0;c16:41/15/0` |
| `20260809-180911-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:36/15/0` |
| `20260809-181539-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:11/0/0;c16:35/15/0` |
| `20260809-182207-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:10/0/0;c16:33/15/0` |
| `20260809-183024-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | discard | `low_sample` | `c1:12/0/0;c16:23/15/0;c32:22/31/0` |
| `20260809-184854-chat` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c4:20/3/0;c8:21/7/0;c16:42/15/0` |
| `20260809-190152-coder` | DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF | coder(4096/1024) | discard | `no_data+nonmonotonic` | `c1:3/0/0;c4:4/3/0;c8:2/7/0;c16:5/15/0` |
| `20260809-192301-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260809-192612-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260809-192921-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260809-193337-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-193648-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-194006-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-194405-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260809-194721-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260809-195038-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260809-195435-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:13/0/0` |
| `20260809-195744-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-200054-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-200450-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260809-200759-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260809-201107-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:12/0/0` |
| `20260809-201601-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260809-201915-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260809-202228-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260809-202622-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-202938-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260809-203254-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-033033-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-033348-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-033704-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-034126-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260810-034443-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260810-034759-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:15/0/0` |
| `20260810-035159-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-035512-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-035823-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-040218-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-040529-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-040840-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-041234-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-041544-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260810-041852-chat` | antirez/DeepSeek-V4-Flash | chat(512/256) | measured | `low_sample` | `c1:14/0/0` |
| `20260815-174443-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:24/0/0;c4:83/3/0;c8:157/7/0;c16:266/15/0;c32:395/32/0` |
| `20260815-183535-coder` | Inferact/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:5/0/0;c4:20/3/0;c8:32/7/0;c16:48/15/0;c32:55/31/0` |
| `20260816-030252-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:170/15/0` |
| `20260816-031322-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:173/15/0` |
| `20260816-032342-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:170/15/0` |
| `20260816-142542-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:170/16/0` |
| `20260816-143609-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:171/15/0` |
| `20260816-144633-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:175/15/0` |
| `20260816-150602-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:187/15/0` |
| `20260816-151632-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/1/0;c16:183/15/0` |
| `20260816-152655-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:191/15/0` |
| `20260816-165725-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:184/15/0` |
| `20260816-170744-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:181/15/0` |
| `20260816-171807-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:179/15/0` |
| `20260816-173728-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:174/15/0` |
| `20260816-174750-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:172/15/0` |
| `20260816-175816-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:173/15/0` |
| `20260816-190354-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:189/15/0` |
| `20260816-191427-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:194/16/0` |
| `20260816-192451-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:192/15/0` |
| `20260816-194425-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:187/16/0` |
| `20260816-195446-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:21/0/0;c16:191/15/0` |
| `20260816-200515-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:188/15/0` |
| `20260816-202448-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:188/15/0` |
| `20260816-203519-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:193/15/0` |
| `20260816-204544-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:190/15/0` |
| `20260816-210549-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/1/0;c16:185/15/0` |
| `20260816-211623-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:192/16/0` |
| `20260816-212644-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/1/0;c16:193/15/0` |
| `20260816-214456-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:187/15/0` |
| `20260816-215519-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:22/0/0;c16:193/15/0` |
| `20260816-220549-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:189/15/0` |
| `20260817-195708-chat` | Inferact/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:12/0/0;c4:46/3/0;c8:72/7/0;c16:113/15/0;c32:136/31/0` |
| `20260817-201312-coder` | Inferact/Qwen3.8-27B-NVFP4 | coder(4096/1024) | discard | `no_data` | `c1:3/0/0;c4:9/3/0;c8:12/7/0;c16:10/16/0;c32:2/31/0` |
| `20260818-082342-coder` | Inferact/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:8/1/0;c4:30/4/0;c8:46/8/0;c16:51/15/0;c32:51/32/0` |
| `20260818-100310-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:9/0/0;c4:29/3/0;c8:52/7/0;c16:87/15/0;c32:127/31/0` |
| `20260818-101929-coder` | unsloth/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:7/0/0;c4:22/3/0;c8:40/7/0;c16:57/15/0;c32:75/31/0` |
| `20260818-130426-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:122/15/0` |
| `20260818-131057-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:16/0/0;c16:125/15/0` |
| `20260818-131724-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:16/0/0;c16:122/15/0` |
| `20260818-133106-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:136/15/0` |
| `20260818-133736-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:134/14/0` |
| `20260818-134356-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:139/15/0` |
| `20260818-135818-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | crash | `errored+low_sample+over_roofline` | `c1:20/0/0;c16:16/0/112069` |
| `20260818-141413-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c16:133/15/0` |
| `20260818-142518-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | crash | `errored+low_sample` | `c1:20/0/0;c16:17/0/107589` |
| `20260818-193258-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:135/15/0` |
| `20260818-193926-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:142/15/0` |
| `20260818-194550-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:138/15/0` |
| `20260818-200804-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c16:141/15/0` |
| `20260818-202029-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c16:136/15/0` |
| `20260818-203920-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `ok` | `c1:20/0/0;c16:138/15/0` |
| `20260818-204548-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:138/15/0` |
| `20260818-205210-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c16:139/15/0` |
| `20260818-210633-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:17/0/0;c4:57/3/0;c8:96/7/0;c16:138/15/0;c32:182/31/0` |
| `20260818-212232-coder` | unsloth/Qwen3.8-27B-NVFP4 | coder(4096/1024) | measured | `low_sample` | `c1:12/0/0;c4:37/3/0;c8:60/7/0;c16:79/15/0;c32:96/31/0` |
| `20260819-191404-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:19/0/0;c16:134/15/0` |
| `20260819-192032-chat` | unsloth/Qwen3.8-27B-NVFP4 | chat(512/256) | measured | `low_sample` | `c1:18/0/0;c16:141/15/0` |

