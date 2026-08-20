# Statistical power of the two gates — what the repo's own record says

**Status:** analysis, for adjudication. Nothing in `eval.sh`, `run_experiment.sh`, `AGENTS.md`,
`program.md` or `docs/validity-contract.md` is changed by this document. Companion tool:
**`scripts/power.py`** (acceptance gate `scripts/power_selftest.sh`, **68 numeric self-checks +
77 CLI checks**, hermetic — no GPU, no network, no lm-eval).

> **REVISION 20260820-b — read this before citing anything below.** An independent audit
> re-derived every number in the first version of this document from the raw journals. The
> **core arithmetic survived** (`--limit` is per leaf subtask; `mmlu@100` is n=5,700 with
> SE 0.509 against lm-eval's own recorded 0.489; every reference value in `power.py` re-checked).
> **Six defects in `power.py` and eight in this document did not**, and one of them was fatal to
> the original recommendation:
>
> * §7's proposed gate contained a **p-value clause that would reject a config compared against
>   itself** — it is **RETRACTED**. §7 is rewritten around what the evidence supports.
> * §2's three-image clustering was wrong: the 81.72 row is **0.24.0, not 0.25.0**. The 0.25.0
>   "cluster" is a single run. The step is **+4.158 pt**, and **"8.5σ" is not reproducible**.
> * §3.1's *"the corpus contains ZERO cross-session same-config `mmlu` replicates"* was **false**,
>   because `config_hash` hashes runbook **comments**. Comment-stripped there are **3** such
>   brackets, spread **0.04 / 0.59 / 0.93 pt**.
> * §4.3's warm-up effect is **two campaigns, not a global law** — and discarding bench #1 is
>   the **largest free improvement available to Gate 3**, which the original missed (§4.5).
> * §4.4's per-model MDE **governs only 34 of the 55 deltas** it was applied to.
>
> Every corrected figure below is re-derived from the committed journals; where the audit's
> number and mine differ, both are shown. `power.py`'s bugs are fixed and each has a selftest
> case that fails without the fix.

Scope: issue #1 §2, and the two open follow-ups
*"`LIMIT=100` accuracy noise (±4–5 pts) is WIDER than the KEEP rule's ~1% tolerance"* and
*"mmlu `LIMIT=100` drifts ~1 pt across sessions on IDENTICAL config+image"*.

Evidence base: **317 `results.tsv` rows**, **79 `accuracy.tsv` rows**, **81 retained lm-eval
bundles** (directories with a `results_*.json`; 104 `*-eval` directories exist) and **295 retained
GuideLLM chat bundles**, across 15 campaigns on `gb10-1988a9714b4e`. *(The first version said 77
and 79; both were undercounts.)*

---

## 0. Headline

| question | answer |
|---|---|
| Is the quality gate “4× too noisy” for its 1% rule? | **Not 4× for either task, and the follow-up's arithmetic is wrong for the one that matters.** `gsm8k@100` really is n=100 — and is **14×** too noisy (MDE 14.08 pt), not 4×. `mmlu@100` is **n=5,700, not 100** (57 leaves), MDE 2.06 pt — **2×**. |
| So how precise is `mmlu@100` in practice? | Its *binomial* SE is 0.509 pt. Its **measured same-config repeat spread is larger**: three brackets moved 0.04, 0.59 and 0.93 pt, a repeat-difference SD of **≈0.64 pt** (§3.1). Binomial theory is a floor, not the answer. |
| What n does the KEEP rule as written (1 point, α .05, power .80) need? | **23,668 items per arm unpaired** — more than `mmlu` *has* (14,042). **1,568–7,848 pairs** paired at the item level (ψ = 0.02–0.10). *(The first version said 23,667/1,567; the tool ceilings.)* |
| So is the 1% clause achievable? | **Not yet, and not by pairing alone.** Unpaired it is unachievable at any limit the lab can afford, *including* `mmlu@full`. Paired the *nominal* MDE is 0.52–1.17 pt — but a **~0.64 pt uncalibrated session term sits underneath it** (§3.1), so that MDE is not reachable today. What is defensible now is a **tolerance band equal to the observed same-config spread: ~0.6 pt typical, ~0.9 pt seen** (§7). |
| Is the throughput gate underpowered? | **Not underpowered — uncalibrated, and inflated by a bias it does not model.** Pooled c16 CV is 2.25%; **discarding the first bench of each bracket takes it to 1.55%** (MDE 6.09% → 4.18%) at zero GPU cost (§4.5). CV is also a per-model property spanning 0.58% to 3.37%. |
| How many historical calls does that change? | Against each model's own **warm-up-corrected** spread, **0 of 55** candidate deltas are unsupported (was 1 of 55). But **21 of the 55 are not same-day comparisons and 6 are cross-image**, and under the variance that actually governs those, four defended 35B deltas flip to unsupported (§4.4). |
| What does `AHL_SEED=42` buy? | Verified real (identical prompt/budget sequences across runs and days). Worth **2.3–2.6× the replicates at c1** — read as "a couple" — and **~1.01×, nothing, at c16**, which is the tuned objective. Caveats in §5. |
| Side-finding that decides the cost | AGENTS.md states *"Speculative decoding ⊥ loglikelihood"* as universal. **Eleven `mmlu@100` rows across three models, all `5700/5700 validity=ok`, come from MTP configs.** The constraint is per-model, not per-feature — probe it (`TASKS=mmlu LIMIT=2`). |
| Is "matched-pair same-session" actually followed? | **63%.** 17 of 27 tuned-candidate quality measurements have a same-day, same-task comparator; 10 do not — including the `kvfp8` runs, the exact numeric-risky class the clause exists for. |

Reproduce every number below with:

```bash
scripts/power.py variance                 # and: variance --drop-first
scripts/power.py keep-rule
scripts/power.py accuracy --task mmlu --limit 100 --delta 1.0 --discordance 0.02
scripts/power.py throughput --level c16 --model RedHatAI/Qwen3.6-35B-A3B-NVFP4
scripts/power.py --root <checkout-with-results/**/data> seed
AHL_POWER_DATA_ROOT=<same checkout> bash scripts/power_selftest.sh
```

`--model` is an **exact, org-qualified** match. It used to be a substring test, so
`--model Qwen3.6-35B-A3B-NVFP4` silently pooled `RedHatAI/…` with `unsloth/…-Fast` and reported
12 brackets / CV 0.61% where the model has 11 / 0.58%. A name matching nothing is now an error.

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
| 20260712 | **`251eba5…` (0.24.0)** | `VLLM-24-…_final.sh` | 81.72 | 0.494 |

**CORRECTED (20260820-b).** The last row was filed under 0.25.0 in the first version. It is not.
`VLLM-24-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh` pins
`vllm/vllm-openai@sha256:251eba5c…` = **v0.24.0**, and the `backend` column of its `results.tsv`
rows agrees (`vllm@0.24.0(img:sha256:251eba5cc7c…)`). It is a 0.24.0 config that happened to be
re-measured on the day the 0.25.0 image was being evaluated — the name says 24 and so does the
digest. So the clusters are:

```
0.23.0 : 78.077 +/- 0.431  (n=3)
0.24.0 : 82.235 +/- 0.582  (n=4)   <- was quoted as 82.41 +/- 0.57 over n=3
0.25.0 : 81.790            (n=1)   <- the "81.76 +/- 0.05 cluster" DOES NOT EXIST
```

Within-cluster spread is consistent with what n=5,700 predicts (SE 0.48–0.54; sd of 3–4 draws
≈ 0.5). The step from 0.23.0 to 0.24.0 is **+4.158 points**, not +4.33.

**"≈ 8.5σ" is withdrawn — it is not reproducible, and the first version never said which σ it
meant.** Three defensible statistics, all pointing the same way:

| statistic | value | what it treats as error |
|---|---|---|
| pooled two-sample *t* on the cluster means | **t = 10.34 on 5 df** (p ≈ 1.5e-4) | the run-to-run spread within each image |
| unpaired two-proportion *z*, n=5,700/arm | **z = 5.57** | binomial error only, one run per arm |
| ratio to a single run's own `acc_stderr` | **7.9×** | lm-eval's reported SE as the whole error |

None of them is 8.5. **The conclusion survives all three**: the 0.23.0→0.24.0 step is a real
effect, not sampling noise, and the project recorded it as noise because the follow-up's SE was
wrong by 2.8×. Quote *which* statistic you mean; the pooled *t* is the honest one, because it is
the only one whose error term includes the session variance §3.1 now measures.

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

**Second correction, same follow-up — and the first version got this one wrong too.**
*"mmlu LIMIT=100 drifts ~1 pt across sessions on IDENTICAL config+image (35B _final: 82.82 on
20260705 vs 81.72 on 20260712, same digest)"*. The **citation** is indeed wrong: 82.82 is
`config_hash 7ca38372`, `20260704_v0.24.0_baseline.sh`, dated **20260704**; 81.72 is
`config_hash 3cdb35e5`, `VLLM-24-…_final.sh`.

But the first version then concluded *"the corpus contains **zero** cross-session same-config
`mmlu` replicates"*, and **that is false**. `config_hash` is `sha256(runbook text)` — it hashes
**comments** — and `promote.sh` creates a `_final.sh` by copying the winning `_tuned.sh` and
prepending a `# Result:` header. **A byte-identical serving configuration therefore gets a new
identity.** Strip full-line comments and **12 runbook pairs across the tree collapse onto 6
distinct configs**, three of which carry `mmlu` accuracy rows:

| effective config | rows | Δ | separation |
|---|---|---|---|
| `20260704_mtp-n2_tuned.sh` == `VLLM-24-…_final.sh` | 82.65, 81.72 | **0.93 pt** | 8 days apart, same 0.24.0 image |
| `baseline.sh` == `VLLM-23-…_final.sh` (35B) | 78.19, 77.60 | **0.59 pt** | same day, same image, same harness |
| `unsloth/…-Fast baseline.sh` (same file, twice) | 81.28, 81.32 | **0.04 pt** | same day |

**So the follow-up's claim is right in substance and wrong in its citation: `mmlu@100` really does
move ~1 point between two runs of the same effective config, and the journal proves it — the
evidence was hidden by a hashing defect, not absent.** This is the single most consequential
correction in this revision, because §7's original recommendation was built on the opposite belief.

`config_hash` hashing comments is a real defect and belongs on the follow-up list: it is the
vLLM-side twin of the tracked *"`config_hash` is blind to HOST-PROCESS launcher settings"* item.
Both make two different things share an identity, or one thing wear two — and both silently break
keep/discard provenance.

---

## 3. What the accuracy record can and cannot support

### 3.1 The empirical basis for accuracy repeatability is TEN brackets, three of them at n=5,700

**REVISED.** The first version grouped on `config_hash` and found six brackets. Grouping on the
**comment-stripped runbook** (§2) finds **ten**, and three at `mmlu@5,700` rather than one:

| model | task | n | values | Δ | note |
|---|---|---|---|---|---|
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | mmlu | 5,700 | 82.65, 81.72 | **0.93 pt** | 8 days apart, same image |
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | mmlu | 5,700 | 78.19, 77.60 | **0.59 pt** | same day, same image, same harness |
| `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | mmlu | 5,700 | 81.28, 81.32 | **0.04 pt** | same day |
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | gsm8k | 100 | 42.0, 40.0 | 2.00 pt | think-**on**, both truncated |
| `RedHatAI/gemma-4-31B-it-NVFP4` | gsm8k | 100 | 73.0, 73.0 | 0.00 pt | baseline == final |
| `RedHatAI/gemma-4-31B-it-NVFP4` | gsm8k | 100 | 68.0, 71.0 | 3.00 pt | the `kvfp8` config |
| `antirez/DeepSeek-V4-Flash` | gsm8k | 100 | 74.0, 74.0 | 0.00 pt | c16 pair |
| `antirez/DeepSeek-V4-Flash` | gsm8k | 100 | 60.0, 76.0 | 16.00 pt | c4 pair; the tracked host-launcher `config_hash` blind spot |
| `unsloth/Qwen3.6-27B-NVFP4` | gsm8k | 100 | 0.0, 98.0 | 98 pt | one row `suspect` (think-off zero-token) |
| `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | gsm8k | 100 | 0.0, 96.0 | 96 pt | one row `suspect` |

**The three `mmlu@5,700` brackets are the number that matters**, because that is the task the
recommendation wants the gate to cite. Their repeat **differences** are 0.04, 0.59, 0.93 pt:

* **RMS repeat difference = 0.636 pt** (equivalently a per-run SD of 0.450 pt).
* The binomial SE of a single `mmlu@100` run is 0.509 pt, so the *difference* of two runs has a
  binomial-only SD of 0.509·√2 = 0.72 pt. The measured 0.64 pt is **within** that — so these
  brackets are not, on their own, proof of an extra session term. They are proof that **0.6–0.9 pt
  is the size of the wobble you must expect**, whatever its mechanism.
* That is **16× the ψ ≈ 0.001 the first version inferred from the single 0.04-pt bracket**, and
  the first version's inference is hereby withdrawn as unrepresentative: it took the smallest of
  three brackets and treated it as the population.

**What the paired model says about these, and why it matters for §7.** Under
`Var(b−c) = nψ`, `E|b−c| ≈ √(2nψ/π)`, the three brackets imply ψ = **0.0014**, **0.312** and
**0.774** respectively. A discordance of 0.77 — three items in four flipping between two runs of
the same config on an 82%-accurate model — is absurd. **So the 0.93-pt bracket is not explainable
as item-level paired noise at any credible ψ**, which is exactly why the p-value half of the
original recommendation had to be retracted (§7).

**The n=100 brackets cannot be compared with the n=5,700 ones by their point spread**, and it is a
mistake to try: at n=100 the score is quantized to whole points, so "0.00 pt" means "the same 73
of 100 items" and nothing finer. Compared as **net item-flip rates** the ordering is:

```
0.0%  gemma baseline/final (n=100)      0.0%  ds4 c16 pair (n=100)
0.04% Fast mmlu (n=5,700)               0.59% 35B mmlu same-day (n=5,700)
0.93% 35B mmlu 8-days-apart (n=5,700)   3.0%  gemma kvfp8 (n=100)
16.0% ds4 c4 pair (n=100, config_hash blind spot)
```

**Read that before believing any story about which serving features cause nondeterminism** — see
§3.5.

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
rows.** Detecting a 1-point drop at p≈.82 needs **23,668** items per arm (the first version said
23,667; the tool ceilings the exact 23,667.x); `mmlu` has 14,042 in total.
The 1% clause has never been supportable by the method the harness uses, at any limit, on any task
in the suite — and raising `LIMIT` cannot fix it, because the tasks run out of questions first.

Paired, `mmlu@LIMIT=100` clears it across the whole defensible discordance range:

| ψ (fraction of items the two configs answer differently) | paired MDE at n=5,700 |
|---|---|
| 0.02 | **0.52 pt** |
| 0.05 | **0.83 pt** |
| 0.10 | **1.17 pt** |

ψ is **not measured anywhere in this repo** — `eval.sh` does not pass `--log_samples`, so no
per-item outcomes exist in any of the 81 retained bundles. The 0.02–0.10 range is a **projection**,
and §3.1's revision shows it is not even well bracketed: the three same-config `mmlu` brackets
imply ψ = 0.0014, 0.312 and 0.774 under the paired-noise model, which spans the entire admissible
range and therefore constrains nothing. **Do not read the paired column as an achievable
tolerance.** It is what the item-level test could deliver *if* the only error were item-level, and
§3.1 shows something else is also moving. Turning `--log_samples` on is what converts ψ from a
projection into a measurement — and §7 specifies the null experiment that has to come first.

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

### 3.5 What the corpus does NOT establish: which serving features cause the wobble

All three `mmlu@5,700` brackets sit on configs carrying **`--enable-prefix-caching`,
`--kv-cache-dtype fp8_e4m3` and MTP together**; both zero-Δ brackets sit on configs carrying
none of them. That looks like a mechanism, and there is independent support for it: measured on
this box, repeating an identical 32-prompt greedy pass gives **7/32 byte-identical outputs with
prefix caching + fp8 KV on, and 32/32 with prefix caching off**.

**Say exactly what that is worth: corroboration, not proof.** n = 3 brackets on one side and 2 on
the other; the three features are confounded with each other *and* with MTP; and the 32-prompt
determinism probe measures the **serving** path, not lm-eval's scoring path, so it establishes
that outputs move — not how far a score moves.

**And the corpus contains a direct counter-example.** The gemma `20260614_kvfp8_tuned.sh` bracket
carries fp8 KV but **no** prefix caching and moved **3 of 100 items** — a 3.0% net flip rate,
*higher* than the 0.93% of the prefix-cache 35B bracket. The `ds4` c4 pair, with neither feature,
moved 16 items. The two 0.00-pt brackets and the two large n=100 brackets are all on the
"features off" side, so the n=100 evidence is bimodal and settles nothing.

The honest summary: **the corpus establishes that same-config `mmlu@5,700` repeats move by up to
0.93 points. It does not establish why, and it does not license a feature-conditional tolerance.**

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
| cross-day | c16 | 3 | 3 | **2.72%** | 1.44% | — | — | 4.47% |

And the same table with the **first bench of every bracket discarded**
(`scripts/power.py variance --drop-first`; the justification is §4.3(a) and the consequence is
§4.5):

| scope | level | brackets | df | pooled CV | median | p75 | p90 | max |
|---|---|---|---|---|---|---|---|---|
| within-experiment | c1 | 75 | 75 | **1.67%** | 0.30% | 0.83% | 2.69% | 7.04% |
| within-experiment | c16 | 63 | 63 | **1.55%** | 0.77% | 1.51% | 2.52% | 5.72% |
| within-day | c16 | 63 | 75 | 1.88% | 0.83% | 1.55% | 2.68% | 5.72% |

Four notes on how to read this.

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
4. **These are different variance components and they are not interchangeable.** The
   within-experiment figure is the right error term for a candidate benched beside its reference
   in one serve session. It is the **wrong** one for a comparison spanning days or images, which
   is what 21 of the 55 historical deltas actually are (§4.4). Quoting the within-experiment CV
   for a cross-day comparison understates the SD by **1.21×** on a like-for-like basis
   (2.72% vs 2.25%), or **1.75×** against the warm-up-corrected 1.55% of §4.5 — and the cross-day
   figure rests on **three brackets**, so it is itself barely an estimate.

### 4.2 The KEEP rule as written, scored

`median c16 beats current best by >3%`, evaluated as a decision rule with N=3 **medians** (the
estimator's sampling SD is 0.6698σ, not σ/√3 = 0.5774σ — the median of 3 is 16% noisier than the
mean of 3, and `power.py` models that):

| level | pooled CV | false-keep on two identical configs | power at a true +3% | two-sided MDE | N for a 5% false-keep rate |
|---|---|---|---|---|---|
| c1 | 1.99% | **5.7%** | 50% | 5.37% | 4 |
| c16 | 2.25% | **8.1%** | 50% | **6.09%** | 4 |
| c1, bench #1 dropped (§4.5) | 1.67% | 3.0% | 50% | 4.50% | 2 |
| **c16, bench #1 dropped (§4.5)** | **1.55%** | **2.2%** | 50% | **4.18%** | **2** |

Two structural facts, neither of which is a defect:

* **"Power at a true +3% is 50%" is not a bug, it is what a threshold is.** A rule of the form
  "keep if the observed ratio exceeds T" fires exactly half the time when the true effect equals T,
  for every N. Raising N does not raise that number; it only sharpens the transition. Anyone
  reading the KEEP rule as "we catch real 3% wins" is reading a coin flip.
* **The 8.1% false-keep rate is the real cost.** Across a 9-candidate wave, that is 0.7 expected
  spurious keeps from configs that do nothing at all. **§4.5 takes it to 2.2% for free**, which is
  why that section is the operative recommendation on this side.

### 4.3 Two systematic effects, both measurable, neither modelled

**(a) The first bench of an experiment is slow at c16.** Over 63 complete 3-bench experiments,
comparing bench `n1` against the mean of `n2`/`n3` on the same config and serve session:

```
c16   mean(n1 / mean(n2,n3) - 1) = -1.22%   sd 3.17%   t = -3.05   39 of 63 negative
c1    mean                       = -0.13%   sd 2.79%   t = -0.40   32 of 75 negative
```

A **1.2% pooled offset at c16, t = −3.05** — 40% of the KEEP threshold. It largely cancels between
a candidate and a reference that are both medians of 3, which is why the loop survives it. It does
**not** cancel when a median-of-3 is compared against a single row, which is exactly the shape of
the FF711 +10.7% "cross-session drift": tune-loop rows 62.30 / 65.20 / 63.51 (median 63.51) vs one
finalize row of 70.32 on the same day and the same `config_hash`. The within-bracket range was
already 4.6%; the finalize row sits 6.8% above the bracket's maximum. Bench order plus a single
observation explains more of that gap than "page-cache state" does, and the record cannot separate
them.

**CORRECTED (20260820-b): this is NOT a global warm-up law, and the first version's framing
oversold it.** Broken out per model over the same 63 experiments:

| model | k | mean(n1 / mean(n2,n3) − 1) | t |
|---|---|---|---|
| `RedHatAI/Qwen3-8B-NVFP4` | 7 | **−5.15%** | −41.6 |
| `WeiboAI/VibeThinker-3B` | 3 | **−5.24%** | −33.7 |
| `RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 8 | −1.95% | −1.1 |
| `RedHatAI/gemma-4-31B-it-NVFP4` | 5 | −2.87% | −2.0 |
| `RedHatAI/Qwen3-Coder-Next-NVFP4` | 3 | −0.45% | −0.4 |
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 10 | +0.07% | +0.3 |
| `Inferact/Qwen3.8-27B-NVFP4` | 10 | +0.23% | +0.4 |
| `unsloth/Qwen3.8-27B-NVFP4` | 4 | +0.36% | +0.4 |
| `DavidAU/…Fable-Fusion-711…` (llama.cpp) | 6 | +0.87% | +0.5 |

**Two campaigns carry the whole pooled effect**, each with a near-deterministic per-experiment
offset (|t| > 30 means the offset is essentially the same every time, not a noisy tendency). Of
the nine models with k ≥ 3, **five are negative and four positive — an exact two-sided sign test
gives p = 1.0**, i.e. indistinguishable from a coin flip. The other seven models lie between
−2.87% and +0.87%.

Two further checks, both of which cut against a mechanistic warm-up story:

* **bench 2 vs bench 3 is flat**: +0.05%, t = 0.17 over the same 63 experiments. Whatever it is,
  it is over after the first bench.
* **it is not prefix caching.** The 12 experiments on configs carrying `--enable-prefix-caching`
  are the **tightest** group at **−0.09%**; the 51 without average −1.48%.

So the honest statement is: *"two campaigns show a large, near-deterministic first-bench offset;
pooled across the corpus this reads as −1.22%, and no mechanism in the record explains it."*
**It is nonetheless worth acting on, and §4.5 is why**: whether or not it is one phenomenon, it is
a *bias* in a fixed position, and removing it shrinks the variance the gate is planned against.

**(b) Temperature correlates weakly with the deviation.** r = **−0.18** at c16 (n=168 rows carrying
a `thermal=` note, 62–77 °C), r = −0.07 at c1. Real but small, and confounded with bench order
since temperature rises through an experiment.

### 4.4 The global CV is the wrong instrument — variance is a per-model property

Pooled c16 CV by model, and what it implies for an N=3 median comparison:

| model | c16 brackets | pooled CV | MDE (N=3) | false-keep at >3% |
|---|---|---|---|---|
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 11 | **0.58%** | **1.54%** | 0.0% |
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
`20260616_moe-cutlass_tuned.sh` on the 120B Nemotron, **+7.95% against an MDE of 9.19%**. *(The
first version quoted +6.83% for this delta; re-deriving it as candidate-median ÷ `baseline.sh`
median over citable chat-c16 rows gives +7.95%. Neither figure changes the verdict, and the
discrepancy is unresolved — it is recorded rather than smoothed over.)*

So: **the throughput gate is not badly underpowered — it is uncalibrated.** The threshold is
global and the variance is not. Six of the 55 configs have too few brackets to say anything at
all, and c4/c8/c32 have none.

#### 4.4.1 CORRECTION: this per-model MDE governs only 34 of the 55 deltas

The audit above applies a **within-experiment, within-session** variance to comparisons that are
frequently neither. Re-derived over the same 55 (candidate median vs `baseline.sh` median, citable
chat-c16 rows only, per-row `backend` column for the image):

| property of the 55 comparisons | count |
|---|---|
| candidate shares a calendar day with its baseline — **within-session variance governs** | **34** |
| candidate does **not** share a day with its baseline | **21** |
| ...of those, also **cross-image** (different `backend` digest on the two sides) | **6** |

All six cross-image comparisons are on the 35B, and **all four deltas §4.4 defends are among
them**: `VLLM-24-…_final.sh` (+4.31%), `20260704_mtp-n2` (+4.26%),
`20260712_moe-marlin-mtp-triton` (+5.11%), `20260712_v0.25.0_baseline` (+4.15%) — every one of
them a 0.24.0/0.25.0 candidate against a **0.23.0** baseline benched three to four weeks earlier.

Under the variance that governs a cross-day comparison — the repo's own cross-day c16 pooled CV,
**2.72%, MDE 7.39%** — **all four flip back to unsupported.**

| delta | vs own-model within-experiment MDE 1.54% | vs cross-day MDE 7.39% |
|---|---|---|
| `VLLM-24-…_final.sh` +4.31% | supported | **unsupported** |
| `20260704_mtp-n2` +4.26% | supported | **unsupported** |
| `20260712_moe-marlin-mtp-triton` +5.11% | supported | **unsupported** |
| `20260712_v0.25.0_baseline` +4.15% | supported | **unsupported** |

**Neither column is "the" answer, and that is the finding.** Say which variance component governs
which comparison:

* **candidate and reference in one session** → within-experiment CV. 34 of 55.
* **different day, same image** → cross-day CV (2.72% at c16, on **3 brackets** — barely an
  estimate). 15 of 55.
* **different image** → there is no error term for this at all. A cross-image delta confounds the
  config change with the image change, and the repo has never benched the same config on two
  images on the same day. 6 of 55, including a promoted artifact.

The practical rule this implies is the one already in the contract for accuracy and not for
throughput: **re-bench the reference in the same session as the candidate.** Where that was not
done, the delta is not separable from session drift and the journal should say so.

### 4.5 The largest free improvement, which the first version missed: discard bench #1

§4.3(a) observed the first-bench offset, correctly noted that it **cancels between two medians**,
and stopped there. It does not cancel in the **variance**, and the variance is what every MDE and
every false-keep rate in this document is computed from. A bias sitting in a fixed position inside
each bracket inflates that bracket's CV.

Recomputed with the first bench of each bracket discarded
(`scripts/power.py variance --drop-first`, `throughput --drop-first`):

| scope | pooled c16 CV as-is | with bench #1 dropped | MDE (N=3) as-is → dropped |
|---|---|---|---|
| **global** | 2.25% | **1.55%** | 6.09% → **4.18%** |
| `RedHatAI/Qwen3-8B-NVFP4` | 3.05% | **0.49%** | 8.29% → 1.31% |
| `WeiboAI/VibeThinker-3B` | 3.09% | **0.11%** | 8.40% → 0.30% |
| `RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 3.37% | **2.17%** | 9.19% → 5.85% |
| `RedHatAI/gemma-4-31B-it-NVFP4` | 2.60% | **1.40%** | 7.05% → 3.77% |
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 0.58% | 0.59% | 1.54% → 1.58% |
| `Inferact/Qwen3.8-27B-NVFP4` | 1.53% | 1.50% | 4.11% → 4.04% |

The two campaigns that carried the pooled offset (§4.3) are the two whose CV nearly **vanishes**
when their first bench goes; the models with no offset are unchanged, which is the consistency
check. Globally the false-keep rate of the `>3%` rule falls from **8.1% to 2.2%** — under the
target the KEEP rule was never scored against — and the N needed for a 5% false-keep rate falls
from 4 to 2.

Re-running §4.4's audit against **warm-up-corrected** per-model MDEs:

| verdict | as-is | warm-up corrected |
|---|---|---|
| \|Δ\| < 3%, correctly rejected | 21 | 21 |
| fires and clears the MDE — supported | 27 | **28** |
| fires but below the MDE — unsupported | **1** | **0** |
| no per-model estimate (<3 brackets) | 6 | 6 |

The one historical call the corpus disputed (`20260616_moe-cutlass`, +7.95% against 9.19%) clears
its model's corrected MDE of **5.85%**. So **"1 of 55 unsupported" becomes "0 of 55"** — the
dispute was an artefact of counting a bias as noise.

**Cost: zero GPU seconds.** It is a change to how existing rows are summarised, and it is
**cheaper than raising N from 3 to 4** (§7's alternatives: +34 min per campaign for a smaller
gain). The two are not exclusive, but this one comes first. The obvious objection — *"you are
throwing away a third of the data"* — is answered by the table: the third being thrown away is
the third with a known bias in it, and the models where that bias is absent barely move.

**Caveat, stated because it is real:** at N=3 this leaves the median of **two** benches, i.e. their
mean, on 63 df instead of 129. The variance estimate is halved in df and the estimator changes
character. If this is adopted the honest form is *"bench 4 times and median the last 3"* (+1 bench
per candidate, ~6 min) rather than *"bench 3 and use 2"* — but even the free version is a strict
improvement on planning against a CV that a bias has inflated.

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
  ragged-tail residual   85-100%     0.12%   <- what pairing does NOT fix
                         60-100%     0.21%      (p90 1.61%, max 4.19%)

  band                     machine SD  workload SD  unpaired SD  SD ratio  ~replicates
  typical (median)             0.58%        0.66%        0.88%     1.53x      2.3x
  planning (MIXED BASIS)       1.99%        2.53%        3.22%     1.62x      2.6x

  c16 projection: 173 requests per stage vs 19 at c1 -> workload term ~0.22% against a
                  machine term of 1.48% -> pairing is worth 1.01x there.
```

Method: with a different seed, the two sides would draw different prompt/budget sets from the same
generator, so the workload term is estimated by bootstrapping each bundle's own request pool
(valid at c1, where requests are served serially and do not interact; **invalid at c16**, hence the
1/√n projection rather than a measurement). The machine term is what the replicate brackets in §4.1
already measure — they are all seed=42, so they are the paired variance by construction.

**Four caveats, all added in 20260820-b, all now printed by the tool itself so they cannot drift
out of the document:**

1. **The bootstrap does not resample the estimator the journal publishes.** It resamples
   `Σtokens / Σlatency`; `results.tsv` records GuideLLM's
   `output_tokens_per_second.successful.mean`, which is a **token-level** mean (its `count` field
   is the token total, not the request total). Median ratio proxy/reported over 260 bundles =
   **0.939**, i.e. the resampled quantity sits ~6% below the number Gate 3 cites. Substituting a
   closer, token-weighted proxy moves the median workload CV by less than 0.02 pt (0.68% → 0.67%),
   so the **conclusion is robust** — but this is a decomposition of a proxy, not of the estimator
   whose variance it claims to decompose, and neither proxy reproduces the published mean exactly.
2. **A c1 stage is time-limited, so its request count `n` is itself random.** A fixed-`n` bootstrap
   holds `n` at whatever was observed and is structurally blind to that term.
3. **The "planning" row is mixed-basis.** Its machine column is a **df-weighted pooled** CV over
   replicate brackets; its workload column is an **unweighted RMS** over per-bundle bootstrap CVs
   (median 0.66% vs RMS 2.53% — a between-model tail that governs no single real comparison). The
   row is an upper band, not a like-for-like ratio, and the tool now labels it `MIXED BASIS`.
4. **The ragged tail should be quoted over the wide window.** The original 85–100% prefix window
   presumes the two configs differ in speed by ≤15%. **11 of the 55 historical candidate deltas
   exceed 40%** (four of them above 50%). Over a 60–100% window the residual is
   **0.21% median / 1.61% p90 / 4.19% max**, roughly double the narrow-window figure at the median
   and at the p90.

Read the "≈2.5 repetitions" headline as an **order of magnitude** — "a couple" — not a figure to
quote to two decimals.

Three conclusions:

1. **At c1 the seed is worth roughly a couple of benchmark repetitions** (2.3–2.6×,
   consistently across both bands: SD ratio 1.53× and 1.62×). A repetition is 6 minutes of stage
   time (two levels at `MAX_SECONDS=180`) plus its share of a ~7-minute serve, so that is real
   money for a one-line default.
2. **At c16 — the tuned objective — it is worth nothing measurable (1.01×).** A c16 stage completes
   ~173 requests against ~19 at c1, so the workload term is already averaged into insignificance
   and machine state dominates. The variance that limits Gate 3 is not addressable by seeding.
3. **The pairing is a prefix pairing with a ragged tail.** A faster config completes *more* of the
   same request sequence within `MAX_SECONDS` (25 vs 21 vs 20 vs 18 requests across the four c1
   bundles above), so the two sides average different prefixes of an identical sequence. That
   residual is small — 0.21% median, 1.61% p90, 4.19% max over the 60–100% window at c1 — but it
   is a *bias* term rather than a noise term, and it grows as the two configs' speeds diverge,
   i.e. precisely when a candidate is winning. Since 11 of 55 historical deltas exceed 40%, the
   wide window is the one to quote.

---

## 6. Is "matched-pair, same session" actually followed? No — 63%

The existing follow-up says *"quality keep/discard comparisons are only valid as same-session
matched pairs — always re-measure the reference in the same session as the candidate."*

Of the **27** task-level quality measurements taken on a `*_tuned.sh` candidate, **17 (63%)** have
another config measured on the same task, limit and think-mode on the same day. *(Re-derived in
20260820-b: unchanged.)* One caveat the first version did not state: this counts a comparator as
present whenever a **different `script`** was measured the same day — and §2 shows two scripts can
be byte-identical once comments are stripped, so a few of the 17 are a config compared with itself
under two names. That inflates the 63% rather than deflating it. **Ten do
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
so its **statistical** floor is the unpaired MDE — 2.06 points on `mmlu@100`, twice the nominal
tolerance.

The first version concluded from this that pairing had to happen at the **item** level, and built
its recommendation on that. **§7.0 retracts the test that was going to exploit the pairing**, but
not this observation: same-session matching remains the single highest-value procedural change
available on the quality side, because §3.1's evidence says the *session* term is what is actually
moving the number. Enforce it; do not read the 2.06-point figure as the achievable tolerance in
either direction.

---

## 7. Recommendation — REWRITTEN 20260820-b, with the p-value half retracted

### 7.0 What was recommended, and why half of it was wrong

The first version recommended a two-part gate:

> *"…requiring exact two-sided p ≥ 0.05 **and** |Δ| ≤ 1.0 point."*

**The p-value half is RETRACTED. It would reject a config compared against itself.**

The arithmetic, from this repo's own numbers. §3.1's largest same-effective-config `mmlu@5,700`
bracket differs by **0.93 points**, i.e. a net item flip of `|b − c| ≈ 53`. For an exact McNemar
test on `b − c = 53`, the p-value depends only on the total discordance `b + c`:

| ψ = (b+c)/5700 | b + c | b | c | exact two-sided p |
|---|---|---|---|---|
| 0.010 | 57 | 55 | 2 | 2.3e-14 |
| 0.020 | 114 | 83 | 31 | **1.2e-06** |
| 0.030 | 171 | 112 | 59 | **6.2e-05** |
| 0.050 | 285 | 169 | 116 | 0.0020 |
| 0.100 | 570 | 311 | 259 | 0.033 |
| **0.1237** | **705** | 379 | 326 | **0.0501** ← first ψ at which the test does not reject |

So the proposed gate returns `p ≥ 0.05` **only if ψ > 0.1237** — better than one item in eight
flipping between two runs of *the same config* on an 82%-accurate model. *(The audit reached the
same conclusion via the normal approximation, `(53/1.96)² = 732` pairs → ψ > 0.128; the exact test
is slightly less demanding at 705. Either way it is one item in eight.)* At the ψ = 0.01–0.03 that
a greedy same-config repeat plausibly produces, the gate returns **p < 10⁻⁴** and **fails the
config against itself**.

This is not a subtle mis-calibration. It is the failure mode of putting a *significance* test where
a *tolerance* test belongs: with n = 5,700 the test is powerful enough to detect differences far
smaller than anyone cares about, and it will detect the session term along with everything else.
The first version's own §3.3 warned that ψ was unmeasured; it did not follow that warning through
to the gate it then proposed. **A projected MDE is not a licence to ship a decision rule.**

**The `|Δ| ≤ 1.0 pt` half survives, and it is what the recommendation now rests on.** Against a
measured repeat-difference SD of 0.64 pt (§3.1), a 1.0-pt band false-fails a config against itself
about **12%** of the time (1.5 pt → 1.8%, 2.0 pt → 0.2%). 12% is high but it is a *tolerance*, and
its failure mode is a wasted re-measurement rather than a wrong promotion.

**And the claimed 0.52–1.17 pt MDE is not reachable today**, because a ~0.64 pt session term of
unknown origin sits underneath it. You cannot resolve half a point through a wobble of two-thirds
of a point.

### 7.1 What to adopt now

> **Adopt the LIMIT correction, `--log_samples`, and `mmlu@5,700` as the task the tolerance
> decision cites. Replace the blanket spec-decode rule with a `TASKS=mmlu LIMIT=2` probe. Restate
> `gsm8k@LIMIT=100` as a breakage detector with its resolution written down. Set the in-loop
> tolerance to the OBSERVED same-config spread — ~0.6 pt typical, ~0.9 pt seen — and put NO
> p-value in the contract until the null experiment in §7.2 has been run. On the throughput side,
> discard bench #1 from every variance estimate (§4.5) and print the model's own MDE on the
> `MEDIAN` line.**

Concrete edits, all outside this document's ownership:

1. **`scripts/eval.sh` — add `--log_samples`.** It writes `samples_<task>_<timestamp>.jsonl` per
   **leaf** into the bundle, which is already gitignored. Cost ~20 MB per `mmlu@100` run, zero GPU
   seconds. This is the enabling change for everything else, and it is worth doing **even though
   the p-value is retracted**: without per-item outcomes the session term cannot be characterised
   at all, and §7.2 cannot be run.
   *Note for whoever wires this up:* `mmlu@100` produces **57 files** per run, not one. That is
   exactly the shape that broke `power.py mcnemar` (§9) — pass them all with
   `--samples-a … --samples-b …`, never concatenated.
2. **Cite `mmlu@5,700`, not `gsm8k@100`, for tolerance.** `eval.sh general` already computes it in
   the same run; the decision has been reading the n=100 figure off the same row. Zero extra GPU
   time.
3. **`AGENTS.md` + `program.md` — the clause becomes**:
   *"accuracy within tolerance — compare `mmlu@LIMIT=100` (n=5,700) between candidate and
   reference, measured in the SAME session at the SAME limit and concurrency. The tolerance is
   **|Δ| ≤ 1.0 point**, which is the observed same-config repeat spread (0.04 / 0.59 / 0.93 pt over
   three brackets, difference SD ≈ 0.64 pt) and NOT a statistical resolution claim: a difference
   inside the band is not separable from session drift, and a difference outside it is a reason to
   re-measure, not a verdict. `gsm8k@LIMIT=100` detects breakage (≈14 pt at 80% power) and nothing
   finer — it must not be cited for a tolerance decision. **No p-value is part of this gate** until
   the null experiment (POWER-analysis §7.2) has been run and its (b, c) recorded."*
4. **Replace the blanket spec-decode rule with a probe.** `TASKS=mmlu LIMIT=2` is 114 items and
   completes in seconds; if it returns finite scores, `mmlu@100` is available for that model. See
   the subsection below — the journal has **eleven** counter-examples to the rule as written.
5. **Correct the two follow-ups and `eval.sh`'s header comment.** *"At LIMIT=100 the binomial SE
   is ~4.3 points"* is true for `gsm8k` and wrong by 2.8× for `mmlu`. And the drift follow-up's
   citation is wrong while **its claim is right** (§2) — fix the citation, keep the claim, and add
   the three brackets as its evidence.
6. **Throughput, zero GPU cost:** have `run_experiment.sh` (a) compute its median over benches
   **2..N** (§4.5) or, better, bench 4 and median the last 3; and (b) append the model's own
   `mde=<x>% false_keep=<y>%` to its `MEDIAN` line from `power.py throughput --model <exact id>
   --drop-first`, refusing to print an MDE when the model has fewer than 3 brackets (6 of 55
   configs). The 3% threshold stays; what changes is that a keep at +4% on the 120B and a keep at
   +4% on the 35B stop looking like the same evidence.
7. **Record which variance component governs each recorded delta** (§4.4.1): same-session,
   cross-day, or cross-image. A cross-image delta has **no error term in this repo at all** and
   should be labelled as a confounded observation rather than a measured effect.
8. **New follow-up: `config_hash` hashes runbook comments** (§2). `promote.sh` copying a winner and
   prepending a `# Result:` header mints a new identity for a byte-identical serving config; 12
   runbook pairs across the tree collapse onto 6 configs when comments are stripped. This hid the
   entire cross-session accuracy replicate evidence for months. It is the vLLM-side twin of the
   tracked host-launcher `config_hash` blind spot and should sit beside it.

### 7.2 The null experiment that MUST run before any p-value enters the contract

Everything paired in this document is a projection over an unmeasured ψ, and §3.1 shows the three
brackets we have imply ψ = 0.0014, 0.312 and 0.774 — the whole admissible range. **Measure it.**

**Design.** One config, two runs, `--log_samples`, `mmlu@LIMIT=100` (n = 5,700, ~17 min per run):

| arm | what varies | why |
|---|---|---|
| A | nothing — two runs back to back in **one serve session** | isolates the within-session item-level term |
| B | two runs in **different sessions** (tear the server down and back up between them) | adds the session term the 0.93-pt bracket implies exists |
| C | arms A and B repeated on a config with **`--enable-prefix-caching` + `--kv-cache-dtype fp8_e4m3`** | the features §3.5 suspects |
| D | arms A and B repeated on a config with **neither** | the control §3.5 needs, because the corpus's n=100 evidence is bimodal |

**Output.** The observed `(b, c)` per arm — from
`scripts/power.py mcnemar --samples-a <57 files> --samples-b <57 files>`. That is the reference
distribution: it tells you what `b + c` and `|b − c|` look like when the answer is known to be
"no difference", for each of the four cells.

**Decision rule that follows from it.** A p-value may enter the contract only if arm A's and arm
B's null distributions both return p ≥ 0.05 at the α you intend to use. If they do not — and §3.1
predicts arm B will not — then the correct object is a **tolerance calibrated on the null**, i.e.
"the candidate must fall inside the same-config band measured here", which is what §7.1(3) says in
the interim using the three historical brackets as a stand-in.

**Cost.** 8 runs × ~17 min ≈ **2.5 hours of GPU time**, plus four serve cycles. That is half a
campaign, once, to convert the entire paired half of this document from projection into
measurement. It is the single highest-value GPU hour available to this project's methodology, and
nothing in §7.1 that touches a p-value should be adopted before it.

**It also closes an open follow-up on the way.** Running arms A/B at `CONC=1` and `CONC=32` instead
of only c16 answers *"Quality has never been measured at c1 or c32"* in the same sitting — the
`conc` column added by contract A9 already records the answer.

### 7.3 The spec-decode constraint — narrower than the contract says, and the journal proves it

`mmlu` is loglikelihood-scored, and AGENTS.md records what looks like a fatal blocker for this
recommendation: *"Speculative decoding ⊥ loglikelihood: a config with `--speculative-config`
(MTP/draft) returns **NaN prompt_logprobs**, so loglikelihood `mmlu` 400s."* **10 of the 15
promoted `_final.sh` runbooks carry `--speculative-config`.**

**The journal contains ELEVEN counter-examples across THREE models** — the first version said
eight, on one model, and undercounted:

| model | rows | scores |
|---|---|---|
| `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 8 | 78.19, 78.44, 77.60, 82.82, 81.75, 82.65, 81.79, 81.72 |
| `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | 2 | 81.28, 81.32 |
| `nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4` | 1 | 83.67 |

Every one was produced by a runbook carrying a **live** `--speculative-config` (`{"method":"mtp",
"num_speculative_tokens":1}` or `…:2}`), and every one recorded `samples=mmlu=5700/5700`,
`validity=ok`, `status=measured`, with a normal `acc_stderr` of 0.48–0.54, across vLLM 0.23.0,
0.24.0 and 0.25.0. The rule is real where it was found (Nemotron-3-Super MTP; the 56,168-request
NaN grind that motivated the 20260817 branch-order fix) but it is **per-model or
per-implementation, not a property of speculative decoding**, and the contract states it as
universal.

> **Caution for anyone re-checking this count.** A naive `grep speculative` over each row's
> runbook also matches **commented-out flags and prose mentions**, which inflates 11 rows to
> **18**, across 7 additional runbooks (`RedHatAI/Nemotron-3-Super-120B` `baseline.sh` and
> `20260616_moe-cutlass_tuned.sh`, plus five other `baseline.sh` files whose headers merely
> *discuss* MTP). Strip full-line comments before matching. The audit that found this reported
> "13 rows / two extra runbooks" using a narrower pattern; the count depends on the pattern, which
> is itself the point.

The probe is trivial and needs no tuning run: `TASKS=mmlu LIMIT=2` is 114 items and completes in
seconds; if it returns finite scores, `mmlu@100` is available for that model. **Use the probe, not
the count** — 11 successes do not prove the twelfth model will work, they only refute the
universal rule.

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

**Every "paired MDE" in the table above is a projection over an unmeasured ψ (§3.3), and §7.0
retracts the p-value that would have consumed it.** They are shown to price the *fallback* task,
not as tolerances to adopt. Read them as: even in the best case, a spec-decode config that cannot
run loglikelihood `mmlu` has a materially coarser quality gate than one that can, and the gap is
worth a one-minute probe to avoid.

So the clause becomes **task-conditional, which it already is for other reasons**:

* **loglikelihood available** (probe passes) → `mmlu@LIMIT=100`, n=5,700, **17 min**. Tolerance:
  the observed same-config band, ~0.6 pt typical / ~0.9 pt seen (§7.1).
* **loglikelihood genuinely closed** → `mmlu_pro@LIMIT=100` think-off, n=1,400, **47 min**, at
  2.4× the binomial SE of `mmlu@100`. Its same-config band has **never been measured** — no
  `mmlu_pro` replicate bracket exists in the corpus — so **record the achieved spread the first
  time two runs of one config are made, and do not assume it is 1%.**

### 7.4 Wall-clock cost — the precise instrument is already being paid for

This is the part that makes the recommendation cheap, and it is easy to miss: **`eval.sh general`
already runs `gsm8k,mmlu` together, and `eval.sh resistant` already runs `mmlu_pro`.** The
in-loop quality check for a numeric-risky candidate has been computing an n=5,700 number all
along — the 6 combined `gsm8k,mmlu@100` bundles took a median of **14.7 minutes** — and then the
KEEP decision has been reading the n=100 `gsm8k` figure off the same row.

Nothing needs to be run for longer. What changes is which number is cited, and that the two sides
of the comparison exist in one session at one limit.

| item | now | proposed | marginal |
|---|---|---|---|
| in-loop eval for a numeric-risky candidate, loglikelihood path | `eval.sh general` = gsm8k+mmlu@100, 14.7 min — **mmlu already computed and then ignored** | same run; cite `mmlu` | **0 min** |
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

Throughput side: **+0 minutes** for §4.5 (it re-summarises rows that already exist). If the
stronger form is wanted — bench 4 and median the last 3 — that is +1 bench per candidate, ~6 min.

**One cost the first version did not price: the null experiment (§7.2), ~2.5 GPU hours, once.**
It is not optional if a p-value is ever to enter the contract, and it is what converts the whole
paired half of this document from projection into measurement.

### 7.5 Why not the alternatives

* **Raise `LIMIT`.** `mmlu@full` costs 42 min instead of 17 and moves the *unpaired* MDE from 2.06
  to 1.30 points — still short of 1.00, and `mmlu` has no more questions to give. `mmlu_pro@full` is
  **8 hours**. Buying precision with samples is the expensive axis and it does not reach the target.
* **Declare `LIMIT=100` a breakage detector and delete the tolerance clause entirely.** Honest and
  free. §7.1 stops just short of it: `gsm8k@100` *is* demoted to a breakage detector, but
  `mmlu@5,700` keeps a tolerance band — calibrated on the observed same-config spread rather than
  on theory. Deleting the clause outright would leave the project with no quality tolerance at all
  on exactly the knobs (kv-cache dtype, quantization, MoE backend) that move accuracy by 1–3 pts.
* **Adopt the paired McNemar p-value.** **Rejected — see §7.0.** It fails a config against itself.
* **Mandate matched-pair same-session comparison.** Necessary, insufficient, and already the
  nominal rule (§6) — followed 63% of the time. It removes the session term, which §3.1 suggests is
  the dominant one, so it is the highest-value *procedural* change available and it should be
  enforced rather than merely stated. It is not a resolution claim on its own.
* **Raise N from 3 to 4 on the throughput side.** Would take the *global* c16 false-keep rate from
  8.1% to 4.6% for about **+34 min per campaign**. **Discarding bench #1 (§4.5) does better, for
  free**: 8.1% → **2.2%**, because it removes a bias rather than averaging over one. Do §4.5 first;
  if more is wanted afterwards, the stronger form ("bench 4, median the last 3") buys both at
  +1 bench, and it should be spent where the model's own CV says it is needed rather than
  uniformly across models whose true need differs 6×.
* **Raise the throughput threshold from 3% to the MDE.** Free, but a *global* MDE of 6.09% would
  reject four 35B keeps including a promoted config (§4.4) — though §4.4.1 shows those four are
  cross-day *and* cross-image, so the global figure is not obviously the wrong one for them. It
  would still pass the Nemotron call at +7.95%. A **per-model, warm-up-corrected** MDE, reported
  beside the delta and labelled with the variance component that governs it (§4.4.1), is the right
  object; gating on it is premature while the per-model CVs rest on 3–11 brackets each.

---

## 8. What this repo's data could not answer

Stated plainly, because the point of this document is to stop plausible numbers being believed.

1. **The discordance rate ψ, for two different configs OR for one config against itself.** No
   `--log_samples`, no per-item outcomes, in any of the 81 retained lm-eval bundles. Every paired
   figure here is a projection, and §3.1 shows the three brackets we have imply ψ = 0.0014, 0.312
   and 0.774 — the entire admissible range, i.e. no constraint at all. **§7.2 is the experiment
   that fixes this, and no p-value should enter the contract before it runs.**
2. **Whether the 4.158-point 35B `mmlu` step was the vLLM image or the `eval.sh` greedy change.**
   Both moved at the same boundary and no matched pair exists (§2). One 17-minute re-run settles it.
3. **The MECHANISM of the same-config wobble.** §3.1 measures it (0.04 / 0.59 / 0.93 pt) and §3.5
   shows the corpus cannot attribute it: the prefix-caching + fp8-KV story is corroborated by an
   out-of-band determinism probe (7/32 vs 32/32 byte-identical) and **contradicted** by the gemma
   `kvfp8` bracket, which has no prefix caching and moved 3 of 100 items. n=3 on one side, n=2 on
   the other, features confounded with each other and with MTP.
4. **The same-config repeat spread of `mmlu_pro` and of `mmlu@full`.** Zero replicate brackets for
   either. The `mmlu_pro` fallback path in §7 therefore has a priced *cost* and an unmeasured
   *tolerance*.
5. **Throughput variance at c4, c8 and c32.** Zero replicate brackets. `power.py` refuses to answer
   rather than extrapolating. Three of the five published tok/s columns have no measured
   reproducibility.
6. **Cross-session throughput variance — and this one now bites.** 6 brackets at c1, **3 at c16**.
   §4.4.1 shows **21 of the 55 historical deltas are cross-day comparisons**, so the variance that
   governs 38% of the record rests on three brackets. Cross-**image** comparisons (6 of 55) have no
   error term in the corpus at all.
7. **What the paired seed buys at c16.** The bootstrap is invalid where requests interact, so §5's
   c16 number is a 1/√n projection of the c1 measurement, not a measurement. Testing it properly
   needs a deliberate unpaired arm — bench one config three times at `AHL_SEED=42` and three times
   at three different seeds — which is ~35 minutes of GPU and has never been run.
8. **Whether quality is batch-dependent** (the open `CONC=1`/`CONC=32` follow-up). Unchanged by this
   work, and it interacts: if accuracy moves with concurrency, any paired comparison must hold
   `conc` fixed as well as `limit`. The `conc` column added by contract A9 makes that checkable,
   and §7.2's null experiment can answer it in the same sitting.
9. **Why `mmlu` succeeded on MTP for the 35B and failed on MTP for Nemotron-3-Super.** The journal
   establishes both facts and explains neither. Candidate discriminators the record cannot separate:
   the model architecture, the MTP implementation (`mtp` vs a draft model), `num_speculative_tokens`
   (1 and 2 both worked on the 35B), and the vLLM version. Until it is understood, the safe
   procedure is the LIMIT=2 probe per (model, image), not a blanket rule in either direction.
10. **Whether the first-bench offset (§4.3) is one phenomenon or several.** Two campaigns carry it
    almost deterministically (|t| > 30) and seven models show nothing. It is not prefix caching
    (those configs are the *tightest* group at −0.09%) and it is over after bench 1 (n2 vs n3 is
    +0.05%). §4.5 acts on it as a bias without claiming to explain it, which is the right order.

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
* **It refuses rather than guessing.** Nonsense inputs (negative CV, `--n` below `b+c`, a `--model`
  matching no row) exit 2 with a reason on stderr. Degenerate-but-real inputs (`--cv 0`, `b=c=0` at
  a real n) are answered in the limit, with a caveat printed. Silent repairs are announced.
* **Every number is verified by execution.** `scripts/power_selftest.sh` runs **68 numeric checks**
  (incomplete beta against hand-computable `I₀.₅(2,3) = 11/16`; Student-t against the published
  table at df 2/3/5/10/30/100; Clopper–Pearson against published (2/20) and (0/10) intervals;
  exact McNemar against `2·P(X≤2 | 10, ½) = 112/1024`; two-proportion n against Fleiss's
  uncorrected 58/arm; McNemar n against Connor's 469 pairs; both validated again by seeded Monte
  Carlo of the actual tests) plus **77 CLI checks** (71 without the gitignored bundles; set
  `AHL_POWER_DATA_ROOT` to a checkout that has them). The shell matcher itself is tested for its
  ability to **fail** — `grep` is line-oriented and silently never matches a multi-line pattern,
  which is the same always-green failure shape as the reachability bugs in the lab notes.

### 9.1 Six defects found by audit, 20260820-b — each with a selftest case that fails without the fix

| # | defect | before | after |
|---|---|---|---|
| 1 | `mcnemar --samples` keyed on `doc_id`, which **restarts at 0 in every leaf task's file**. lm-eval writes one file per leaf, so `mmlu@100` is 57 files a side; concatenating overwrote across leaves. | a 2-leaf × 5-doc input reported **`pairs 5`**; on a real run it would report McNemar on **n=100 while the operator believed 5,700** | keyed on `(task, doc_id)`; `--samples-a`/`--samples-b` accept **N files** per side and the output names the leaves pooled. Reports `pairs 10`. Hand-concatenated files are now a duplicate-key **error**. |
| 2 | `--model` was a **substring** filter, and this CLI is what §7.1(6) wires into `run_experiment.sh` | `--model Qwen3.6-35B-A3B-NVFP4` also matched `unsloth/…-Fast`: **12 brackets / CV 0.61%** instead of 11 / 0.58%. `--model NVFP4` pooled nine models. | exact, org-qualified match; a name matching nothing exits 2 and lists the known models |
| 3 | crashes on legitimate input | `accuracy --p 0` and `throughput --cv 0` both raised **uncaught `ZeroDivisionError`** — and `p=0` is real here (think-off zero-token `gsm8k=0.0` rows) | `--p 0`/`--p 1` refuse with an explanation (a degenerate proportion has no MDE); `--cv 0` is **answered in the zero-spread limit** with a caveat that a k=3 CV of 0 is a small-sample artefact |
| 4 | accepted nonsense confidently | `--cv -5` returned a full report computed from \|log1p(−0.05)\|; `mcnemar --b 5 --c 5 --n 3` printed `psi = 3.3333` and `MDE 206.60 points`; `--b 0 --c 0` printed `psi = nan` | all three refuse (exit 2) with the reason; `b=c=0` at a **real** n is answered as psi=0, MDE undefined |
| 5 | silent parameter repair | `n_mcnemar` set ψ := δ when ψ < δ while `cmd_accuracy` printed the **user's** ψ: `--delta 5.0 --discordance 0.02` printed `psi = 0.020` beside an answer computed at 0.05 | `mcnemar_psi_floor()` returns the flag; the output prints `!! psi RAISED to 0.050`, and `--json` carries `paired.discordance_repaired` |
| 6 | assorted | mismatched `--samples` files silently **intersected**; `throughput` printed `power at +X%` twice under one label with possibly different values; the doc said 23,667/1,567 while the tool printed 23,668/1,568 | mismatched sides refuse unless `--allow-partial` (which prints a `!! PARTIAL` banner); the two power lines are labelled `power AT the threshold` / `power at the true effect`; the doc now quotes the tool |

Additions in the same pass, both so that this document's claims are checkable rather than quoted:
**`--drop-first`** on `throughput`/`variance`/`keep-rule` (§4.5), and four printed caveats on
`seed` (§5) covering the proxy estimator, the random `n`, the mixed-basis band and the wide
ragged-tail window.

---

*First written 20260820 against commit-time `results.tsv` (317 rows) and `accuracy.tsv` (77 rows —
the real count is 79). Revised 20260820-b after an independent audit re-derived every number from
the raw journals: `power.py` bug fixes, §2 / §3.1 / §3.5 / §4.3 / §4.4.1 / §4.5 / §5 corrections,
and §7 rewritten with its p-value clause retracted.*
