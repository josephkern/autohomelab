# Statistical power of the two gates — what the repo's own record says

**Status:** analysis + one recommendation, for adjudication. Nothing in `eval.sh`,
`run_experiment.sh`, `AGENTS.md`, `program.md` or `docs/validity-contract.md` is changed by this
document. Companion tool: **`scripts/power.py`** (acceptance gate `scripts/power_selftest.sh`,
**56 numeric self-checks + 35 CLI checks**, hermetic — no GPU, no network, no lm-eval).

Scope: issue #1 §2, and the two open follow-ups
*"`LIMIT=100` accuracy noise (±4–5 pts) is WIDER than the KEEP rule's ~1% tolerance"* and
*"mmlu `LIMIT=100` drifts ~1 pt across sessions on IDENTICAL config+image"*.

Evidence base: **317 `results.tsv` rows**, **77 `accuracy.tsv` rows**, **79 retained lm-eval
bundles** and **295 retained GuideLLM chat bundles**, across 15 campaigns on `gb10-1988a9714b4e`.

---

## 0. Headline

| question | answer |
|---|---|
| Is the quality gate “4× too noisy” for its 1% rule? | **Not 4× for either task, and the follow-up's arithmetic is wrong for the one that matters.** `gsm8k@100` really is n=100 — and is **14×** too noisy (MDE 14.08 pt), not 4×. `mmlu@100` is **n=5,700, not 100** (57 leaves), MDE 2.06 pt — **2×**. |
| What n does the KEEP rule as written (1 point, α .05, power .80) need? | **23,667 items per arm unpaired** — more than `mmlu` *has* (14,042). **1,567–7,847 pairs** if the comparison is paired at the item level (ψ = 0.02–0.10). `mmlu@LIMIT=100` already supplies 5,700. |
| So is the 1% clause achievable? | **Only as a paired test, and only on a grouped task.** Unpaired it is unachievable at any limit the lab can afford — *including* `mmlu@full`. Paired on `mmlu@100` the MDE is **0.52–1.17 points**, and that run is **already being made** by `eval.sh general`; the decision just cites the `gsm8k` number beside it instead. |
| Is the throughput gate underpowered? | **Not underpowered — uncalibrated.** Globally, pooled CV c16 2.25% gives an N=3 MDE of 6.09% and an 8.1% false-keep rate. But CV is a *per-model* property spanning **0.58% (35B) to 3.37% (120B Nemotron)**, i.e. MDE 1.54% to 9.19%. Judged against its own model's spread, exactly **1 of 55** historical candidate deltas is unsupported. |
| What does `AHL_SEED=42` buy? | Verified real (identical prompt/budget sequences across runs and across days). Worth **~1.6× on the SD ≈ 2.5 benchmark repetitions at c1**, and **~1.01× — nothing — at c16**, which is the tuned objective. |
| Side-finding that decides the cost | AGENTS.md states *"Speculative decoding ⊥ loglikelihood"* as universal. **Eight `mmlu@100` rows in the journal, all `5700/5700 validity=ok`, come from MTP configs** across three vLLM versions. The constraint is per-model, not per-feature — probe it (`TASKS=mmlu LIMIT=2`) rather than assume it. |
| Is "matched-pair same-session" actually followed? | **63%.** 17 of 27 tuned-candidate quality measurements have a same-day, same-task comparator; 10 do not — including the `kvfp8` runs, the exact numeric-risky class the clause exists for. |

Reproduce every number below with:

```bash
scripts/power.py variance
scripts/power.py keep-rule
scripts/power.py accuracy --task mmlu --limit 100 --delta 1.0 --discordance 0.02
scripts/power.py --root <checkout-with-results/**/data> seed
bash scripts/power_selftest.sh
```

---

## 1. The arithmetic error at the centre of the follow-up

`lm_eval --limit L` is applied **per leaf subtask**, not per task group. `mmlu` has 57 leaves and
`mmlu_pro` has 14, so:

| task at `LIMIT=100` | leaves | effective n | binomial SE at its typical p | lm-eval's own reported SE (median over bundles) |
|---|---|---|---|---|
| `gsm8k` | 1 | **100** | 2.7 pt @ p=.92 | 1.97 pt (k=31) |
| `mmlu_pro` | 14 | **1,400** | 1.23 pt @ p=.70 | **1.20 pt** (k=14) |
| `mmlu` | 57 | **5,700** | 0.51 pt @ p=.82 | **0.49 pt** (k=24) |

The right-hand column is not my computation — it is `acc_stderr` as **lm-eval wrote it into every
bundle we kept**. The instrument has been publishing its own precision all along, and it says
0.49 points for the number the follow-up calls ±4.3.

The repo already knows this in one place and not the other. `AGENTS.md`'s `accuracy.tsv` schema
section (contract A9) states it explicitly — *"`mmlu --limit 100` legitimately requests **5,700**
docs (57 subtasks × 100)"* — while the follow-up two sections later, and the comment in
`scripts/eval.sh` that justifies Gate 2 having no value-threshold, both assume n=100 and quote
±4.3 points. **The follow-up is right about `gsm8k` and wrong about `mmlu` by a factor of 7.6 in
n**, i.e. 2.8× in SE.

That matters in both directions:

* it makes the quality gate **better** than believed for the task it actually cites, and
* it makes the *evidence* the follow-up rests on **unexplainable as sampling noise**, which is
  section 2.

---

## 2. The "35B mmlu 77.6 → 82.82 across 7 runs" evidence, decomposed

All eight `mmlu@100` rows on `RedHatAI/Qwen3.6-35B-A3B-NVFP4`, with the pinned image digest:

| date | image | config | mmlu | lm-eval SE |
|---|---|---|---|---|
| 20260614 | `6d8429e…` (0.23.0) | `baseline.sh` | 78.19 | 0.531 |
| 20260614 | `6d8429e…` | `20260614_moe-auto_tuned.sh` | 78.44 | 0.531 |
| 20260614 | `6d8429e…` | `VLLM-23-…_final.sh` | 77.60 | 0.538 |
| 20260704 | `251eba5…` (0.24.0) | `20260704_v0.24.0_baseline.sh` | **82.82** | 0.482 |
| 20260704 | `251eba5…` | `20260704_moe-auto_tuned.sh` | 81.75 | 0.494 |
| 20260704 | `251eba5…` | `20260704_mtp-n2_tuned.sh` | 82.65 | 0.481 |
| 20260712 | `fc56161…` (0.25.0) | `20260712_v0.25.0_baseline.sh` | 81.79 | 0.494 |
| 20260712 | `fc56161…` | `VLLM-24-…_final.sh` | 81.72 | 0.494 |

The 5.2-point "spread" is **three tight clusters, one per image**:

```
0.23.0 : 78.08 +/- 0.43 (sd of 3)
0.24.0 : 82.41 +/- 0.57
0.25.0 : 81.76 +/- 0.05
```

Within-cluster spread is exactly what n=5,700 predicts (SE 0.48–0.54; sd of 3 draws ≈ 0.5).
Between cluster 1 and cluster 2 the gap is **+4.33 points ≈ 8.5σ**. That is not noise. It is a
real, reproducible, three-configs-deep shift that the project recorded as noise **because the
follow-up's SE was wrong by 2.8×** — with a correct SE, a 4.3-point move across an image bump is
the single loudest quality signal in the entire accuracy journal.

**What the data cannot tell us is the cause.** Two things changed at that boundary and the record
cannot separate them:

* the pinned image, 0.23.0 → 0.24.0, and
* `eval.sh` itself — commit `b0f092e` (2026-06-15) pinned greedy sampling. The bundles prove the
  harness differed: the 20260614 runs carry `gen_kwargs={'max_gen_toks': 1024}`, the 20260704 runs
  carry `{'max_gen_toks': 1024, 'temperature': 0, 'top_p': 1.0, 'presence_penalty': 0,
  'frequency_penalty': 0}`.

There is no matched pair anywhere in the corpus that holds one fixed while moving the other. A
single 17-minute `mmlu@100` run of `20260614_moe-auto_tuned.sh` on today's `eval.sh` and today's
image would settle it; nothing shorter will.

**Second correction, same follow-up.** *"mmlu LIMIT=100 drifts ~1 pt across sessions on IDENTICAL
config+image (35B _final: 82.82 on 20260705 vs 81.72 on 20260712, same digest)"* — 82.82 is
`config_hash 7ca38372`, `20260704_v0.24.0_baseline.sh`, dated **20260704**; 81.72 is
`config_hash 3cdb35e5`, `VLLM-24-…_final.sh`. Different config, different runbook, different date
from the one quoted. The corpus contains **zero** cross-session same-config `mmlu` replicates, so
the claim it makes is not merely mis-cited — it is unsupported by any row in the journal.

---

## 3. What the accuracy record can and cannot support

### 3.1 The entire empirical basis for accuracy repeatability is six brackets

Grouping on identical (model, `config_hash`, task, `limit`, `think`, `conc`):

| model | task | n | values | range | note |
|---|---|---|---|---|---|
| `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | mmlu | 5,700 | 81.28, 81.32 | **0.04 pt** | |
| `antirez/DeepSeek-V4-Flash` | gsm8k | 100 | 74.0, 74.0 | 0.00 pt | |
| `RedHatAI/gemma-4-31B-it-NVFP4` | gsm8k | 100 | 68.0, 71.0 | 3.00 pt | within binomial |
| `antirez/DeepSeek-V4-Flash` | gsm8k | 100 | 60.0, 76.0 | 16.00 pt | the tracked `config_hash` blind spot |
| `unsloth/Qwen3.6-27B-NVFP4` | gsm8k | 100 | 0.0, 98.0 | 98 pt | one row `suspect` (think-off zero-token) |
| `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | gsm8k | 100 | 0.0, 96.0 | 96 pt | one row `suspect` |

Four usable brackets, one of them above n=100. **The repo cannot characterise accuracy
repeatability from its own history** and this document does not pretend otherwise.

The one high-n bracket is nonetheless informative. Two runs of an identical config differing by
**0.04 points at n=5,700** means the net discordance `|b − c|` is about **2 items**. Under the
paired model `Var(b − c) = nψ`, `E|b − c| ≈ sqrt(2nψ/π)`, so `|b−c| = 2` implies
**ψ ≈ 0.001** — one item in a thousand — for a config compared against *itself* under greedy
decoding. Serving nondeterminism contributes ~0.04 points to `mmlu`, not 5. (n=1 bracket; treat as
an order of magnitude, not an estimate.)

A second, independent hint: on 20260704 two genuinely different 35B configs (`v0.24.0_baseline`
and `mtp-n2`) both scored `mmlu_pro=68.21` — **byte-identical at n=1,400**, i.e. the same 955
items right. That is what greedy-lossless MTP plus a fixed item set looks like, and it is exactly
the regime where a paired test is enormously more powerful than comparing two headline numbers.

### 3.2 `LIMIT=100` is not a random subsample, and its scores are offset from `full`

`--limit` takes the **first** L docs of each leaf's split. On the one model measured both ways
(`Qwen3-8B-NVFP4`, `20260613_kvfp8_tuned.sh`):

| task | `LIMIT=100` | `full` | delta |
|---|---|---|---|
| mmlu | 73.25 (n=5,700) | 70.99 (n=14,042) | **−2.26 pt** |
| gsm8k | 92.0 (n=100) | 87.64 (n=1,319) | −4.36 pt |

The `LIMIT=100` set is a *subset* of the full set, so this is not a two-sample comparison and no
z-score applies; what it shows is that the first 100 docs of each leaf are systematically easier
than the remainder, on both tasks, by more than the mmlu SE (0.51 pt). **In-loop and finalize
numbers for the same config are not interchangeable.** Any comparison must hold `limit` fixed —
which the `limit` column already records, and which the recommendation below relies on.

### 3.3 Power, computed

`scripts/power.py keep-rule` (α .05, power .80, two-sided):

```
  gsm8k     limit=100  n=100     MDE unpaired 14.08 pt | paired(psi=0.05)   n/a pt | ~   4 min
  mmlu      limit=100  n=5,700   MDE unpaired  2.06 pt | paired(psi=0.05)  0.83 pt | ~  17 min
  mmlu_pro  limit=100  n=1,400   MDE unpaired  4.96 pt | paired(psi=0.05)  1.67 pt | ~  47 min
  gsm8k     limit=full n=1,319   MDE unpaired  3.21 pt | paired(psi=0.05)  1.72 pt | ~  49 min
  mmlu      limit=full n=14,042  MDE unpaired  1.30 pt | paired(psi=0.05)  0.53 pt | ~  42 min
  mmlu_pro  limit=full n=12,032  MDE unpaired  1.67 pt | paired(psi=0.05)  0.57 pt | ~ 405 min
```

Read that table twice. **No row in the unpaired column clears 1.00 point, including the two `full`
rows.** Detecting a 1-point drop at p≈.82 needs 23,667 items per arm; `mmlu` has 14,042 in total.
The 1% clause has never been supportable by the method the harness uses, at any limit, on any task
in the suite — and raising `LIMIT` cannot fix it, because the tasks run out of questions first.

Paired, `mmlu@LIMIT=100` clears it across the whole defensible discordance range:

| ψ (fraction of items the two configs answer differently) | paired MDE at n=5,700 |
|---|---|
| 0.02 | **0.52 pt** |
| 0.05 | **0.83 pt** |
| 0.10 | **1.17 pt** |

ψ is **not measured anywhere in this repo** — `eval.sh` does not pass `--log_samples`, so no
per-item outcomes exist in any of the 79 retained bundles. The 0.02–0.10 range is a projection
bracketed by the two measurements in §3.1 (ψ≈0.001 for a config against itself; ψ must exceed the
observed accuracy gap for two different configs). Turning `--log_samples` on converts it from a
projection into a measurement on the first comparison that uses it.

### 3.4 Cost per effective sample — the cheap gate is the precise one

Median seconds per effective sample, from `total_evaluation_time_seconds` in the retained bundles:

| task | s/sample | why |
|---|---|---|
| `mmlu` | **0.178** | loglikelihood: one scored forward pass per choice, no generation |
| `humaneval`/`mbpp` | 0.57 | short generations |
| `mmlu_pro` | 2.02 | generative CoT |
| `gsm8k` | 2.22 | generative CoT |
| `aime24/25` | 124.8 | 32k-token long CoT |

`mmlu` is **12× cheaper per sample than `gsm8k`** and supplies **57× more samples at the same
`LIMIT`**. The in-loop gate has been spending its 4 minutes on the least informative task
available to it: `gsm8k@100` costs 3.7 minutes and resolves nothing below ~14 points.

---

## 4. What the throughput record says

### 4.1 Replicate spread

`scripts/power.py variance`, over rows the validity contract calls citable at the level cited:

| scope | level | brackets | df | pooled CV | median | p75 | p90 | max |
|---|---|---|---|---|---|---|---|---|
| within-experiment (`exp=` tag) | c1 | 78 | 153 | **1.99%** | 0.58% | 1.47% | 3.32% | 7.32% |
| within-experiment | c16 | 66 | 129 | **2.25%** | 1.48% | 2.68% | 3.18% | 5.70% |
| within-day | c1 | 79 | 176 | 1.91% | 0.61% | 1.49% | 3.32% | 7.32% |
| within-day | c16 | 67 | 142 | 2.32% | 1.48% | 2.51% | 3.18% | 5.70% |
| cross-day (session medians) | c1 | 6 | 6 | 2.89% | 1.35% | — | — | 6.28% |
| cross-day | c16 | 3 | 3 | 2.72% | 1.44% | — | — | 4.47% |

Three notes on how to read this.

1. **Plan against the pooled CV, not the median.** A CV estimated from k=3 is a noisy χ² quantity
   whose median sits well below its true value; the median of 78 such estimates is badly
   downward-biased. The pooled figure (`sqrt(Σ df·cv² / Σ df)`) is the variance estimate. The gap
   between 0.58% and 1.99% at c1 is not a contradiction, it is a heavy tail — and the tail is not
   random: the noisiest c16 brackets are systematically the 120B Nemotron (5.70%, 5.45%), the
   llama.cpp Q6_K (5.30%) and gemma-4 (4.25%), so **plan per model** (`power.py throughput --model`
   does, and says loudly when it has to fall back).
2. **c4, c8 and c32 have no replicate brackets at all.** `LEVELS_SET=1,16` means the tuning loop
   never repeats them, and the full sweeps are one-offs. `power.py throughput --level c32` exits 4
   rather than answering. The repo has **no variance estimate for three of its five published
   columns**, and the c32 column in particular is the one the "chat still scales at c32 (+47%)"
   lab note rests on.
3. **The cross-day rows are 3 and 6 brackets.** They cannot support the "~10% cross-session drift"
   lab note, and they do not refute it either — the FF711 case that note cites (`8b07e87b`, tune
   median 63.51 vs finalize 70.32, **+10.7%**) is real, is the same `config_hash` on the same
   **day**, and is a comparison of a median-of-3 against a **single** row. See §4.3.

### 4.2 The KEEP rule as written, scored

`median c16 beats current best by >3%`, evaluated as a decision rule with N=3 **medians** (the
estimator's sampling SD is 0.6698σ, not σ/√3 = 0.5774σ — the median of 3 is 16% noisier than the
mean of 3, and `power.py` models that):

| level | pooled CV | false-keep on two identical configs | power at a true +3% | two-sided MDE | N for a 5% false-keep rate |
|---|---|---|---|---|---|
| c1 | 1.99% | **5.7%** | 50% | 5.37% | 4 |
| c16 | 2.25% | **8.1%** | 50% | **6.09%** | 4 |

Two structural facts, neither of which is a defect:

* **"Power at a true +3% is 50%" is not a bug, it is what a threshold is.** A rule of the form
  "keep if the observed ratio exceeds T" fires exactly half the time when the true effect equals T,
  for every N. Raising N does not raise that number; it only sharpens the transition. Anyone
  reading the KEEP rule as "we catch real 3% wins" is reading a coin flip.
* **The 8.1% false-keep rate is the real cost.** Across a 9-candidate wave, that is 0.7 expected
  spurious keeps from configs that do nothing at all.

### 4.3 Two systematic effects, both measurable, neither modelled

**(a) The first bench of an experiment is slow at c16.** Over 63 complete 3-bench experiments,
comparing bench `n1` against the mean of `n2`/`n3` on the same config and serve session:

```
c16   mean(n1 / mean(n2,n3) - 1) = -1.22%   sd 3.17%   t = -3.05   39 of 63 negative
c1    mean                       = -0.13%   sd 2.79%   t = -0.40   32 of 75 negative
```

A **1.2% warm-up bias at c16, p ≈ 0.003** — 40% of the KEEP threshold. It largely cancels between
a candidate and a reference that are both medians of 3, which is why the loop survives it. It does
**not** cancel when a median-of-3 is compared against a single row, which is exactly the shape of
the FF711 +10.7% "cross-session drift": tune-loop rows 62.30 / 65.20 / 63.51 (median 63.51) vs one
finalize row of 70.32 on the same day and the same `config_hash`. The within-bracket range was
already 4.6%; the finalize row sits 6.8% above the bracket's maximum. Bench order plus a single
observation explains more of that gap than "page-cache state" does, and the record cannot separate
them.

**(b) Temperature correlates weakly with the deviation.** r = **−0.18** at c16 (n=168 rows carrying
a `thermal=` note, 62–77 °C), r = −0.07 at c1. Real but small, and confounded with bench order
since temperature rises through an experiment.

### 4.4 The global CV is the wrong instrument — variance is a per-model property

Pooled c16 CV by model, and what it implies for an N=3 median comparison:

| model | c16 brackets | pooled CV | MDE (N=3) | false-keep at >3% |
|---|---|---|---|---|
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 11 | **0.58%** | **1.54%** | 0.03% |
| `RedHatAI/Qwen3-Coder-Next-NVFP4` | 3 | 1.28% | 3.43% | 0.7% |
| `unsloth/Qwen3.8-27B-NVFP4` | 5 | 1.47% | 3.96% | 1.6% |
| `Inferact/Qwen3.8-27B-NVFP4` | 10 | 1.53% | 4.11% | 2.0% |
| `RedHatAI/gemma-4-31B-it-NVFP4` | 5 | 2.60% | 7.05% | 11.2% |
| `DavidAU/…Fable-Fusion-711…` (llama.cpp) | 6 | 2.97% | 8.07% | 14.3% |
| `RedHatAI/Qwen3-8B-NVFP4` | 8 | 3.05% | 8.29% | 14.9% |
| `WeiboAI/VibeThinker-3B` | 3 | 3.09% | 8.40% | 15.2% |
| `RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 8 | **3.37%** | **9.19%** | 17.3% |

**A 6× spread in CV, a 6× spread in MDE, and a 500× spread in false-keep rate.** The KEEP rule
applies one threshold to all of them. Planning against the global pooled 2.25% is wrong in both
directions: it over-states the risk on the 35B by 4× and under-states it on the 120B by 1.5×.

That changes the audit. For every config with ≥2 valid chat-c16 rows, the delta of its median
against its campaign's `baseline.sh` median (n=55 configs), judged **against its own model's MDE**:

| verdict | count |
|---|---|
| \|Δ\| < 3% — below the KEEP threshold, correctly rejected | 21 (38%) |
| fires **and** clears the per-model MDE — supported | 27 (49%) |
| fires but is **below** the per-model MDE — unsupported | **1 (2%)** |
| no per-model variance estimate (<3 brackets) | 6 (11%) |

Judged against the *global* MDE of 6.09%, four deltas look unsupported —
`VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` (+4.31%), `20260704_mtp-n2_tuned.sh` (+4.26%),
`20260712_moe-marlin-mtp-triton_tuned.sh` (+5.11%), `20260712_v0.25.0_baseline.sh` (+4.15%) — and
one of them is a promoted artifact. **All four are on the 35B, the tightest-variance model in the
corpus (MDE 1.54%), and all four are comfortably supported by its own replicates.** Using the
global number here would have manufactured a problem that does not exist, which is the same class
of error as the ±4.3-point figure in §1.

Exactly **one** historical call is unsupported by the model's own spread:
`20260616_moe-cutlass_tuned.sh` on the 120B Nemotron, **+6.83% against an MDE of 9.19%**.

So: **the throughput gate is not badly underpowered — it is uncalibrated.** The threshold is
global and the variance is not. Six of the 55 configs have too few brackets to say anything at
all, and c4/c8/c32 have none.

---

## 5. What the paired `AHL_SEED=42` design actually buys

`bench.sh` pins `AHL_SEED` (default 42) so candidate and reference are issued identical synthetic
prompts. **First: it works.** Comparing the per-request records of four separate `c1` chat bundles
of `Inferact/Qwen3.8-27B-NVFP4` — different runs, different days — the output-token budget sequence
is identical element for element (`352, 280, 300, 312, 202, 156, 184, 278, …`) and the prompt-token
sequence matches on every shared index. The pairing is not aspirational.

**Second: quantify it rather than assert it.** `scripts/power.py seed` decomposes the variance of a
comparison using 260 retained c1 bundles:

```
  median requests per c1 stage      19
  output-budget CV within a stage   25.9%    <- what the seed holds identical
  ragged-tail residual              0.12%    <- what pairing does NOT fix

  band            machine SD   workload SD   unpaired SD   SD ratio   ~replicates
  typical (median)     0.58%        0.68%        0.89%      1.54x        2.4x
  planning (pooled)    1.99%        2.54%        3.23%      1.62x        2.6x

  c16 projection: 173 requests per stage vs 19 at c1 -> workload term ~0.22% against a
                  machine term of 1.48% -> pairing is worth 1.01x there.
```

Method: with a different seed, the two sides would draw different prompt/budget sets from the same
generator, so the workload term is estimated by bootstrapping each bundle's own request pool
(valid at c1, where requests are served serially and do not interact; **invalid at c16**, hence the
1/√n projection rather than a measurement). The machine term is what the replicate brackets in §4.1
already measure — they are all seed=42, so they are the paired variance by construction.

Three conclusions:

1. **At c1 the seed is worth about 2.5 benchmark repetitions**, consistently across both bands
   (SD ratio 1.54× and 1.62×). A repetition is 6 minutes of stage time (two levels at
   `MAX_SECONDS=180`) plus its share of a ~7-minute serve, so that is real money for a one-line
   default.
2. **At c16 — the tuned objective — it is worth nothing measurable (1.01×).** A c16 stage completes
   ~173 requests against ~19 at c1, so the workload term is already averaged into insignificance
   and machine state dominates. The variance that limits Gate 3 is not addressable by seeding.
3. **The pairing is a prefix pairing with a ragged tail.** A faster config completes *more* of the
   same request sequence within `MAX_SECONDS` (25 vs 21 vs 20 vs 18 requests across the four c1
   bundles above), so the two sides average different prefixes of an identical sequence. That
   residual is small — 0.12% median, 0.79% p90, 2.15% max at c1 — but it is a *bias* term rather
   than a noise term, and it grows as the two configs' speeds diverge, i.e. precisely when a
   candidate is winning.

---

## 6. Is "matched-pair, same session" actually followed? No — 63%

The existing follow-up says *"quality keep/discard comparisons are only valid as same-session
matched pairs — always re-measure the reference in the same session as the candidate."*

Of the **27** task-level quality measurements taken on a `*_tuned.sh` candidate, **17 (63%)** have
another config measured on the same task, limit and think-mode on the same day. **Ten do
not** (nine rows below; the first carries two tasks):

```
20260614-075213  RedHatAI/Qwen3-8B-NVFP4          20260613_kvfp8_tuned.sh    gsm8k=87.64, mmlu=70.99
20260615-015232  RedHatAI/gemma-4-31B-it-NVFP4    20260614_kvfp8_tuned.sh    mmlu_pro=46.29
20260616-054847  RedHatAI/Nemotron-3-Super-120B   20260616_moe-cutlass_tuned mmlu=85.82
20260616-182743  RedHatAI/Nemotron-3-Super-120B   20260616_mtp-n1_tuned.sh   gsm8k=59.36
20260616-190907  RedHatAI/Nemotron-3-Super-120B   20260616_mtp-n1_tuned.sh   mmlu_pro=74.16
20260817-203815  Inferact/Qwen3.8-27B-NVFP4       20260816_mtp-n3_tuned.sh   gsm8k=95.45
20260817-210412  Inferact/Qwen3.8-27B-NVFP4       20260816_mtp-n3_tuned.sh   mmlu_pro=66.81
20260818-222152  unsloth/Qwen3.8-27B-NVFP4        20260818_mtp-n3_tuned.sh   gsm8k=95.98
20260818-224316  unsloth/Qwen3.8-27B-NVFP4        20260818_mtp-n3_tuned.sh   mmlu_pro=70.38
```

The first two are `kvfp8` — a KV-cache-dtype change, the canonical numeric-risky knob the ~1%
clause was written for. Both were measured with no same-day comparator, and the Qwen3-8B one was
measured at a **different `limit`** from its reference as well (§3.2: worth −2.26 points on mmlu on
its own).

**And even where the rule *is* followed it does not deliver what it promises.** Same-session
matching removes the between-session component, but the comparison is still between two *scores*,
so its floor is the unpaired MDE — **2.06 points on `mmlu@100`**, twice the tolerance. Pairing has
to happen at the **item** level to buy anything. That is the crux of the recommendation.

---

## 7. Recommendation — one change, priced

> **Keep `LIMIT=100`. Move the KEEP rule's `~1%` accuracy clause off `gsm8k` and onto a *paired
> McNemar test* on `mmlu@LIMIT=100` (n=5,700), which requires adding `--log_samples` to `eval.sh`.
> Restate `gsm8k@LIMIT=100` in the contract as a breakage detector with its resolution written
> down (≈14 points at 80% power), never citable for a tolerance decision. Leave the throughput
> rule's N=3 and >3% threshold exactly as they are, and print the campaign's **own** MDE and
> false-keep rate — `power.py throughput --model <this model>` — on every `MEDIAN` line.**

Five concrete edits, all outside this document's ownership:

1. **`scripts/eval.sh`** — add `--log_samples` to the lm-eval invocation. It writes
   `samples_<task>_*.jsonl` into the bundle, which is already gitignored. Cost: ~20 MB per
   `mmlu@100` run, zero GPU seconds. This is the entire enabling change.
2. **`scripts/suite.sh` / the tuning loop** — for a **numeric-risky** candidate (kv-cache-dtype,
   quantization, GEMM/MoE backend), run the same `eval.sh general` that is already run, but also
   run it on the **reference in the same session at the same `limit`**, and cite the `mmlu` number
   rather than the `gsm8k` one. Where loglikelihood is genuinely unavailable for the model, use
   `eval.sh resistant` (`mmlu_pro@100`) on both sides instead.
3. **`AGENTS.md` + `program.md`** — the clause becomes:
   *"accuracy within ~1% — evaluated as `scripts/power.py mcnemar --samples <ref>.jsonl
   <cand>.jsonl` on `mmlu@LIMIT=100`, requiring exact two-sided p ≥ 0.05 **and** |Δ| ≤ 1.0 point.
   `gsm8k@LIMIT=100` detects breakage (>=14 pt) and nothing finer. Where loglikelihood is
   unavailable, `mmlu_pro@LIMIT=100` paired, and RECORD the achieved tolerance (1.1-2.4 pt
   depending on the measured psi) instead of claiming 1%."*
   Record the measured ψ in the logbook — after the first few comparisons the projection in §3.3
   becomes a measurement and the MDE stops being an assumption.
4. **Correct the arithmetic in the two follow-ups and in `eval.sh`'s header comment** (`"At
   LIMIT=100 the binomial SE is ~4.3 points"` — true for `gsm8k`, wrong by 2.8× for `mmlu`), and
   correct the mis-cited 82.82-vs-81.72 pair in the drift follow-up.
5. **Throughput, zero GPU cost:** have `run_experiment.sh` append the model's own
   `mde=<x>% false_keep=<y>%` to its `MEDIAN` line, from `power.py throughput --model`, and refuse
   to print an MDE when the model has fewer than 3 brackets (§4.4 shows this is 6 of 55 configs).
   The threshold stays at 3%; what changes is that a keep at +4% on the 120B and a keep at +4% on
   the 35B stop looking like the same evidence.

### The spec-decode constraint — narrower than the contract says, and the journal proves it

`mmlu` is loglikelihood-scored, and AGENTS.md records what looks like a fatal blocker for this
recommendation: *"Speculative decoding ⊥ loglikelihood: a config with `--speculative-config`
(MTP/draft) returns **NaN prompt_logprobs**, so loglikelihood `mmlu` 400s."* **10 of the 15
promoted `_final.sh` runbooks carry `--speculative-config`.**

**The journal contains eight counter-examples.** Every one of the 35B `mmlu@100` rows in §2 —
78.19, 78.44, 77.60, 82.82, 81.75, 82.65, 81.79, 81.72 — was produced by a runbook carrying
`--speculative-config '{"method":"mtp","num_speculative_tokens":1}'` or `…:2}`, and every one
recorded `samples=mmlu=5700/5700`, `validity=ok`, `status=measured`, with a normal `acc_stderr` of
0.48–0.54. Across vLLM 0.23.0, 0.24.0 and 0.25.0. The rule is real where it was found
(Nemotron-3-Super MTP; the 56,168-request NaN grind that motivated the 20260817 branch-order fix)
but it is **per-model or per-implementation, not a property of speculative decoding**, and the
contract states it as universal.

That is worth an independent check by whoever adjudicates this, because it decides the cost of the
recommendation. The probe is trivial and needs no tuning run: `TASKS=mmlu LIMIT=2` is 114 items and
completes in seconds; if it returns finite scores, `mmlu@100` is available for that model.

Where the loglikelihood path genuinely *is* closed, the clause falls back to a generative task,
paired the same way:

| task for a spec-decode config | n | paired MDE ψ=.02 / .05 / .10 | unpaired MDE | cost |
|---|---|---|---|---|
| `mmlu_pro@LIMIT=100` think-off | 1,400 | **1.06 / 1.67 / 2.37 pt** | 4.96 pt | 47 min |
| `mmlu_pro@LIMIT=200` | 2,800 | 0.75 / 1.18 / 1.67 pt | 3.48 pt | 94 min |
| `mmlu_pro@LIMIT=300` | 4,200 | 0.61 / 0.97 / 1.37 pt | 2.84 pt | 141 min |
| `gsm8k@full` think-off | 1,319 | 1.09 / 1.72 / 2.44 pt | 3.21 pt | 49 min |

(The `LIMIT=200`/`300` rows assume every `mmlu_pro` leaf holds at least that many items; the repo
has only ever run `LIMIT=100` and `full`, so `power.py` computes those two from measured
`accuracy.tsv` values and the others from `leaves x limit`. Verify the per-leaf counts before
quoting them.)

So the clause becomes **task-conditional, which it already is for other reasons**:

* **loglikelihood available** (probe passes) → `mmlu@LIMIT=100`, paired, MDE 0.52–1.17 pt,
  **17 min**. The 1% rule is met.
* **loglikelihood genuinely closed** → `mmlu_pro@LIMIT=100` think-off, paired, MDE
  **1.06–2.37 pt**, **47 min**. The 1% rule is met only at low discordance; at ψ=0.05 the honest
  tolerance is ~1.7 points and `LIMIT=200` (94 min) is what buys ~1.2. **Write the achieved
  tolerance into the logbook rather than pretending it is 1%.**

Pairing is what makes either of these tractable: unpaired, the same two tasks sit at 2.06 and
4.96 points and no affordable limit rescues them.

### Wall-clock cost — the precise instrument is already being paid for

This is the part that makes the recommendation cheap, and it is easy to miss: **`eval.sh general`
already runs `gsm8k,mmlu` together, and `eval.sh resistant` already runs `mmlu_pro`.** The
in-loop quality check for a numeric-risky candidate has been computing an n=5,700 number all
along — the 6 combined `gsm8k,mmlu@100` bundles took a median of **14.7 minutes** — and then the
KEEP decision has been reading the n=100 `gsm8k` figure off the same row.

Nothing needs to be run for longer. What changes is which number is cited, and that the two sides
of the comparison exist in one session at one limit.

| item | now | proposed | marginal |
|---|---|---|---|
| in-loop eval for a numeric-risky candidate, loglikelihood path | `eval.sh general` = gsm8k+mmlu@100, 14.7 min — **mmlu already computed and then ignored** | same run; cite `mmlu`, test it paired | **0 min** |
| `--log_samples` | — | writes `samples_*.jsonl` into the (gitignored) bundle | **0 GPU s**, ~20 MB/run |
| same-session reference for that candidate (§6: missing 37% of the time) | often a different day or a different `limit` | one `eval.sh general` on the reference in the same session | **+15 min per comparison** |
| the same, where loglikelihood is genuinely closed | `eval.sh general TASKS=gsm8k` = 3.7 min | `eval.sh resistant` ×2 (candidate + reference) = 94 min | **+87 min per comparison** |
| loglikelihood probe for a new model | — | `TASKS=mmlu LIMIT=2` (114 items) | **< 1 min, once per model** |

**How often does this bill arrive? Six times in fifteen campaigns.** Only 6 tuned candidates in
the whole history touch a numeric-risky knob and also carry an eval row
(`20260613_kvfp8`, `20260614_kvfp8`, `20260616_moe-cutlass`, `20260614_moe-auto`,
`20260704_moe-auto`, `20260704_mtp-n2`) — **0.4 per campaign** — and four of the six already have
`mmlu@5,700` measured. Applying the recommendation retrospectively to the entire published record
would have cost roughly **one hour of GPU time in total**, and the median campaign's ~5 h is
unchanged.

Throughput side: **+0 minutes.** No extra benches are proposed.

### Why not the alternatives

* **Raise `LIMIT`.** `mmlu@full` costs 42 min instead of 17 and moves the *unpaired* MDE from 2.06
  to 1.30 points — still short of 1.00, and `mmlu` has no more questions to give. `mmlu_pro@full` is
  **8 hours**. Buying precision with samples is the expensive axis and it does not reach the target.
* **Declare `LIMIT=100` a breakage detector and delete the 1% clause.** Honest, free, and what §3.3
  forces if pairing is rejected — but it discards a clause that becomes achievable for one CLI flag,
  and it leaves the project with *no* quality tolerance test at all, on a lab whose stated
  numeric-risky knobs are exactly the ones that move accuracy by 1–3 points.
* **Mandate matched-pair same-session comparison.** Necessary, insufficient, and already the
  nominal rule (§6). It removes the session term but leaves a 2.06-point floor because the pairing
  is at the score level. It should stay in the contract; it is not an answer on its own.
* **Raise N from 3 to 4 on the throughput side.** Would take the *global* c16 false-keep rate from
  8.1% to 4.6% for about **+34 min per campaign** — comparable in cost to the whole accuracy fix,
  to sharpen a rule that §4.4 shows has made exactly one unsupported call. And it spends the money
  uniformly across models whose true need differs 6× (0.58% CV on the 35B vs 3.37% on the 120B).
  Defer it. If it is ever wanted, spend it where the model's own CV says it is needed.
* **Raise the throughput threshold from 3% to the MDE.** Free, but a *global* MDE of 6.09% would
  reject four supported 35B keeps including a promoted config (§4.4), while still passing the one
  genuinely unsupported Nemotron call at +6.83%. It gets both classes wrong, which is what a global
  threshold does to a per-model variance. A **per-model** MDE is the right object — and reporting
  it (edit 5) is strictly better than gating on it while the per-model CVs still rest on 3–11
  brackets each.

---

## 8. What this repo's data could not answer

Stated plainly, because the point of this document is to stop plausible numbers being believed.

1. **The discordance rate ψ between two different configs.** No `--log_samples`, no per-item
   outcomes, in any of the 79 retained lm-eval bundles. Every paired figure here is a projection
   over ψ ∈ [0.02, 0.10]. First comparison run with the flag on measures it.
2. **Whether the 4.33-point 35B `mmlu` shift was the vLLM image or the `eval.sh` greedy change.**
   Both moved at the same boundary and no matched pair exists (§2). One 17-minute re-run settles it.
3. **Run-to-run accuracy variance in general.** Four usable replicate brackets, one above n=100
   (§3.1). Everything said here about accuracy *repeatability* rests on binomial theory plus lm-eval's
   own `acc_stderr`, corroborated by a single 0.04-point bracket.
4. **Throughput variance at c4, c8 and c32.** Zero replicate brackets. `power.py` refuses to answer
   rather than extrapolating. Three of the five published tok/s columns have no measured
   reproducibility.
5. **Cross-session throughput variance.** 6 brackets at c1, 3 at c16. Enough to say the pooled
   figure is not wildly different from the within-session one; nowhere near enough to characterise
   the tail the FF711 note is about.
6. **What the paired seed buys at c16.** The bootstrap is invalid where requests interact, so §5's
   c16 number is a 1/√n projection of the c1 measurement, not a measurement. Testing it properly
   needs a deliberate unpaired arm — bench one config three times at `AHL_SEED=42` and three times
   at three different seeds — which is ~35 minutes of GPU and has never been run.
7. **Whether quality is batch-dependent** (the open `CONC=1`/`CONC=32` follow-up). Unchanged by this
   work, and it interacts: if accuracy moves with concurrency, a paired McNemar comparison must hold
   `conc` fixed as well as `limit`. The `conc` column added by contract A9 makes that checkable.
8. **Why `mmlu` succeeded on MTP for the 35B and failed on MTP for Nemotron-3-Super.** The journal
   establishes both facts and explains neither. Candidate discriminators the record cannot separate:
   the model architecture, the MTP implementation (`mtp` vs a draft model), `num_speculative_tokens`
   (1 and 2 both worked on the 35B), and the vLLM version. Until it is understood, the safe
   procedure is the LIMIT=2 probe per (model, image), not a blanket rule in either direction.

---

## 9. The tool

`scripts/power.py` — stdlib only, no scipy. Subcommands: `accuracy`, `throughput`, `keep-rule`,
`variance`, `seed`, `mcnemar`, `selftest`.

Design commitments worth naming:

* **It reads the repo's own replicate brackets** for the throughput side rather than assuming a
  distribution, reports the bracket count and degrees of freedom behind every CV, falls back from a
  per-model estimate to the global pool **only with a `!! FELL BACK` line**, and **exits 4 rather
  than answering** for a level with no replicates.
* **It models the estimator the loop actually uses.** SD of a sample *median* of N, computed by
  order-statistic quadrature — separately for odd N (1-D Simpson) and even N (a triangular-domain
  cumulative integral, because the two central order statistics of an even sample are consecutive,
  and a product-Simpson rule over the square runs 2–5% low). Both are checked against the published
  finite-n efficiency table to 0.03% and against seeded Monte Carlo.
* **It is honest about pairing.** The `accuracy` output prints the unpaired and paired columns side
  by side with the assumed ψ, and states in the footer that ψ is unmeasured in this repo.
* **Every number is verified by execution.** `scripts/power_selftest.sh` runs 56 numeric checks
  (incomplete beta against hand-computable `I₀.₅(2,3) = 11/16`; Student-t against the published
  table at df 2/3/5/10/30/100; Clopper–Pearson against published (2/20) and (0/10) intervals;
  exact McNemar against `2·P(X≤2 | 10, ½) = 112/1024`; two-proportion n against Fleiss's
  uncorrected 58/arm; McNemar n against Connor's 469 pairs; both validated again by seeded Monte
  Carlo of the actual tests) plus 35 CLI checks. Note that the shell matcher itself is tested for
  its ability to **fail** — `grep` is line-oriented and silently never matches a multi-line
  pattern, which is the same always-green failure shape as the reachability bugs in the lab notes.

---

*Written 20260820 against commit-time `results.tsv` (317 rows) and `accuracy.tsv` (77 rows).*
