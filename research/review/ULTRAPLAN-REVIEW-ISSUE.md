# [Review] Ultraplan review of autohomelab: correctness of the measurement pipeline, gate design, and what "validated" actually certifies

**POSTED:** https://github.com/josephkern/autohomelab/issues/1 (2026-08-19). This file is the
source of record for the issue body; edit here and update the issue if it changes.

## Why now

The project has reached a scale where its conclusions are being trusted operationally:

| | count |
|---|---|
| promoted `_final` configs | 15 |
| campaigns with results | 15 |
| benchmark rows in `results.tsv` | 313 |
| accuracy rows in `accuracy.tsv` | 76 |
| scripts | 27 (~2,240 lines) |
| runbooks | 104 across 15 model dirs |
| host-process launchers | 18 |
| open follow-ups in AGENTS.md | 10 |

Two campaigns closed in the last 48h (`Inferact/Qwen3.8-27B-NVFP4`, `unsloth/Qwen3.8-27B-NVFP4`),
and in the course of them **three separate harness defects were found by hand, each of which had
been silently producing or nearly producing wrong published numbers.** That is the trigger for this
review: the failure mode of this codebase is not a crash, it is a plausible number.

## Scope requested

1. Current code (`scripts/`, `backends/`, `launchers/`)
2. Goals — is the charter in `AGENTS.md` still the right objective function?
3. Benchmarks — methodology, statistical validity, coverage
4. Final output — what a promoted `_final.sh` certifies, and to whom

Plus the six areas below, which this session's findings argue are load-bearing.

---

## 1. HIGHEST PRIORITY — measurement validity: the harness emits confident wrong numbers

The project's only product is measurements, and the pipeline has no validity layer. Three
independent instances in one session:

| defect | symptom | how it was caught |
|---|---|---|
| `suite.sh` ran loglikelihood `mmlu` on a spec-decode config | 56,168 requests each returning `400 NaN`, progress bar advancing normally for 1h15m; would have reported a score computed over whatever subset avoided a NaN | noticed a progress bar with an odd request count |
| coder shape starved at `MAX_SECONDS=180` | c32 = 256.19 tok/s computed from **2 completed requests**; non-monotonic curve (c8 70.88 > c16 68.88) written as `status=measured` | eyeballed the curve shape |
| MTP n=4 crashed the server mid-stage | `tps_c16` of **449,358** and **1,992.87** written to the journal, from a handful of requests returning instantly against a dead endpoint | the number was absurd enough to notice |

**None of these produced an error.** All three wrote `status=measured` rows. Two were caught only
because a human looked at the shape of the numbers.

**Questions for review:**
- Should `bench.sh` refuse to write a row that fails invariants — minimum `successful` count per
  level, monotonicity sanity, tok/s within a physical bound derived from model bytes × memory
  bandwidth? (A 449,358 tok/s row is refutable from first principles on a 273 GB/s box.)
- Should `results.tsv` carry the `successful`/`incomplete`/`errored` counts per level, so validity is
  auditable after the fact rather than requiring the raw bundle?
- `MAX_SECONDS` is recorded, but the fact that a *baseline* used 600 and a *finalize* used the 180
  default was invisible until the curves were compared. Should the row record the full effective
  knob set?
- Is `status` expressive enough? `measured` currently covers "good data" and "the server was dead".

## 2. Statistical power — the gates cannot resolve what the rules ask of them

- **Quality:** the KEEP rule requires accuracy "within ~1%" for numeric-risky knobs, but the in-loop
  eval is `LIMIT=100`, where binomial SE at p≈0.9 is **±4–5 points**. Observed spreads match exactly:
  35B mmlu ranged **77.6 → 82.82** over 7 runs of near-identical configs. **The quality gate is
  ~4× too noisy for the decision rule it feeds.** It can catch gross breakage; it cannot certify 1%.
- **Throughput:** N=3 median against a >3% KEEP threshold, while observed run-to-run spread on
  identical configs reached ~4%, and *cross-session* drift on one config hit **10.7%** (FF711). We
  handle this ad hoc by re-measuring a reference in-session; it is not enforced by the harness.

**Questions:** what sample size would the quality gate need to support a 1% rule — or should the rule
be restated honestly as "detects gross regression only"? Should in-session reference re-measurement
be mandatory in `run_experiment.sh` rather than a convention people remember?

## 3. What does a promoted `_final` actually certify? (benchmark-vs-deployment gap)

Concrete case from today: `VLLM-27-unsloth_Qwen3.8-27B_NVFP4_final.sh` was promoted with all three
gates green — and serves **`--max-model-len 8192` against a model whose native context is 262,144**.
The value came from `gen_baseline.py`, survived four tuning waves untouched because it is not a
throughput knob, and no gate examined it because both benchmark shapes fit inside it.

The gap generalises:

| the harness optimises | production actually does |
|---|---|
| median c16 throughput | interactive single-user (c1) via OpenWebUI |
| quality measured **thinking-OFF** | served **thinking-ON** |
| 512/256 and 4096/1024 shapes | arbitrary, including long context |
| 8,192 context | up to 262,144 |

**Questions:** should `_final` mean "fastest under our benchmark" or "best config to actually serve"?
If the latter, should promotion require a deployment-profile check (context, thinking-on behaviour,
c1 latency) rather than only the tuned objective? Should we ship *two* artifacts — a throughput
config and a serving config?

## 4. Coverage blind spots

- **Accuracy has only ever been measured at one concurrency.** `eval.sh` hardcodes `CONC=16` by
  default and nothing in the repo has ever overridden it; `accuracy.tsv` has no `conc` column. Gate 2
  sits at c16 while Gate 3 sweeps 1→32 — **they never cross.** We have zero evidence about output
  quality at c1 or c32. Mechanisms that could plausibly make output batch-dependent exist (GEMM
  reduction order, CUDA-graph capture-size fallback, spec-decode rejection sampling, hybrid Mamba
  state under prefix-caching `align`, preemption/recompute).
- **No long-context quality signal at all** — every eval is short-prompt.
- **No private held-out set** (existing follow-up) — every gate task is public and contamination-prone.
- **`coder` c1 is structurally sample-limited** (~12 requests max per 600 s stage).

## 5. Tuning-loop ROI — is flag tuning the right primary activity?

Across the two most recent campaigns, on the same base model:

| lever | result |
|---|---|
| MTP speculative depth | **+53.2%** |
| checkpoint choice (same model, different NVFP4 build) | **+16.9%** at baseline, and **+3.57 pts mmlu_pro** |
| everything else — kv fp8, prefix caching, gpu-util, batched tokens, KDA backend, `qwen3_5_mtp`, `max-num-scheduled-tokens`, DSpark, `--async-scheduling` | **0 for 9** |

Nine consecutive negatives. The two things that mattered were a *speculation* setting and a
*procurement* decision. **Question:** should the program's default loop lead with checkpoint
comparison and speculation, and treat the serving-flag matrix as a low-yield tail? What is the
expected value of a candidate wave, given this hit rate?

## 6. Reproducibility and provenance gaps

- **`config_hash` is blind to host-process launcher settings.** ds4 recorded gsm8k
  60.0/76.0/74.0/74.0 under one identical hash (60 vs 76 is ~3.7σ). The hash derives from a
  `.smoke-runbook.sh` stub that cannot see the launcher's `DSPARK`/`NP`/`CTX` values, so distinct
  configs share provenance.
- Cross-session comparability is a convention, not a mechanism (see §2).
- `promote.sh` derives its version tag by grepping the first `vX.Y.Z` in the runbook text, which
  catches migration comments; the workaround is remembering to pass `VLLM_TAG=`.

## 7. Unresolved defects worth a decision

- **GB10 engine wedge** — 10 events on this node across 4 vLLM versions and 4 models, including
  **two at concurrency 1**. Matches open upstream [vllm-project/vllm#43885]. A lab note claimed it
  was "RESOLVED by per-level isolation" in June; **nine of the ten events occurred after that
  mitigation**. Dossier, forensics protocol and a drafted (unposted) upstream comment are in
  `research/upstream/vllm-43885-gb10-wedge.md`.
- **MTP n=4 intermittently fatal at c16** (2 of 3 attempts) — undiagnosed; no container log captured.
- **Grammar-forced `tool_choice` 500s on the 35B production serve** — tracked, upstream cluster known.
- Should we be contributing upstream more systematically? We hold reproduction data on at least two
  open issues.

---

## 8. A capacity dimension the harness does not model at all — and the one tool that could have caught it is wrong (added 2026-08-19)

Follow-up to §3, with the root cause traced and a second defect found underneath it.

### 8a. Root cause: how a `_final` came to serve 1/32 of its model's context

`VLLM-27-unsloth_Qwen3.8-27B_NVFP4_final.sh` serves `--max-model-len 8192` against a 262,144-native
model. The chain:

1. `gen_baseline.py` emits `--max-model-len 8192` as a hardware-derived default.
2. It is **not a throughput knob**, so no tuning candidate in four waves ever touched it.
3. Both benchmark shapes (`chat` 512/256, `coder` 4096/1024) **fit inside it**, so no gate ever
   pressured it.
4. It therefore rode through 4 tuning waves and 3 gates unexamined, into a promoted artifact.

No single step is wrong. The gap is that **nothing in the pipeline asks "what workloads can this
config actually serve?"** — only "how fast is it on ours, and is it still accurate?"

### 8b. `kv_calc.py` over-estimates KV by 1.87x on hybrid architectures

The one tool that exists to answer the capacity question gives the wrong number for this arch:

```
kv_calc.py assumed:  256.0 KiB/token   (2 · 64 layers · 4 kv_heads · 256 head_dim · 2 B)
engine reported:     283,989 tokens in a 36.99 GB pool at util 0.5
=> MEASURED:         136.6 KiB/token   -> calculator is 1.87x high
```

Cause: it multiplies by **all** `num_hidden_layers`. `qwen3_5` is a hybrid — **48 of 64 layers are
Gated DeltaNet**, which carry per-sequence state, not per-token KV; only 16 layers hold real KV.
The script *detects* this and prints `(hybrid attention detected — KV is an over-estimate)`, but
still emits the wrong `kv/token` and, worse, a wrong `util` recommendation.

Concretely: it says c8 @ 32K context needs `util 0.72`. Measurement says it **already fits at
util 0.5**. The error is in the conservative direction, so acting on it would have under-provisioned
context or over-provisioned memory on a unified-memory box where high util destabilises the host.

### 8c. Context and concurrency trade against one pool, and nothing records the envelope

From the measured 283,989-token pool at util 0.5:

| context used | max concurrent full-length sequences |
|---|---|
| 8,192 | 34.7 |
| 32,768 | 8.7 |
| 65,536 | 4.3 |
| 262,144 | **1.08** |

Long-context serving on this node is **single-stream at native context**, and that is arithmetic,
not a tunable. Note also that the promoted 8192 is *accidentally* matched to the benchmark ceiling:
32 x 8192 = 262,144 ≈ the 283,989-token pool. **The context setting was implicitly chosen by the
sweep's top concurrency level, not by anyone.**

### Questions

- Should promotion require a **capacity statement** — the (context x concurrency) envelope a config
  supports — alongside tok/s and accuracy? A `_final` that cannot state what it can serve is
  under-specified for its stated purpose ("the canonical config to serve").
- Should `kv_calc.py` respect `layer_types` / `full_attention_interval` and compute per-arch KV,
  rather than detecting hybrids and warning while still returning the wrong figure?
- Should `kv_calc.py` be wired into `gen_baseline.py` so `--max-model-len` is a *derived, recorded*
  decision rather than a default nobody revisits?
- Should `results.tsv` record the engine's `GPU KV cache size` so the envelope is derivable per row?

---

## 9. The benchmark shapes do not resemble the workload the models are actually deployed into (added 2026-08-19)

The harness has exactly two shapes:

| shape | prompt | output |
|---|---|---|
| `chat` | 512 | 256 |
| `coder` | 4,096 | 1,024 |

**All 313 rows in the results journal use one of these two.** No measurement anywhere in the project
uses a prompt longer than 4,096 tokens, on models whose native context is 262,144.

The actual deployment pattern for this node is **one long-context orchestrator (>66k, targeting
~128k) fanning out to many short-context subagents**. Neither shape represents either half of that:
the orchestrator is 16–32x longer than our longest prompt, and the subagent fan-out is a
concurrency-of-short-sequences pattern that `chat` approximates only accidentally.

### Why this compounds the other findings

- **The tuned objective may be optimising for a workload nobody runs.** `median c16 chat(512/256)` is
  the target every keep/discard decision in every campaign was made against. If production is "one
  128k sequence plus a handful of 8k ones", the ranking of configs under that objective is not known
  to transfer. MTP depth, for instance, was chosen at c16 with 512-token prompts; its optimum is
  already known to move with batch size, and nothing tells us where it sits at 128k.
- **It made us discard the single most relevant optimisation for the real workload.**
  `--enable-prefix-caching` measured **-0.54%** and was discarded — because GuideLLM synthetic prompts
  share no prefix, so the benchmark *cannot* observe prefix reuse. An orchestrator resending a growing
  context every turn is the canonical shared-prefix case; the same flag is reported elsewhere as worth
  14-22x on prefill for 19k/53k shared prefixes. **The harness is structurally blind to it**, and the
  campaign record currently says "bench-neutral, keep for real traffic" on intuition rather than data.
- **The capacity envelope (§8) only becomes visible at deployment scale.** At 512-token prompts,
  context and concurrency never contend; at 128k they trade directly against one pool.

### Questions

- Should the shape set include one or more **deployment-representative shapes** — e.g. a long-context
  shape (64k-128k prompt) and an orchestrator/subagent mix — rather than only synthetic short ones?
- Should the tuning objective be **per-deployment-profile** rather than a single global `median c16
  chat`? A config tuned for batch-throughput and a config tuned for a long-context orchestrator are
  not obviously the same config.
- Should GuideLLM's synthetic data be supplemented with a **shared-prefix generator**, so
  prefix-caching effects are measurable at all? Any flag whose benefit only appears under prefix reuse
  is currently guaranteed to measure as noise.
- More generally: **what evidence would justify a `_final` for a given deployment?** Today the answer
  is "it won on a 512-token benchmark", which is a weaker claim than the artifact's name implies.

---

## Suggested review output

1. A severity-ranked defect list for the measurement pipeline (§1) with proposed invariants.
2. A decision on what `_final` certifies (§3) — and whether promotion criteria change.
3. A statistical-power recommendation for both gates (§2).
4. A recommendation on loop priorities given the 0-for-9 flag hit rate (§5).
5. Triage of the 10 open AGENTS.md follow-ups against the above.

## Pointers

- Charter and lab notes: `AGENTS.md` · procedure: `program.md`
- Gate definitions: `docs/validation.md` · harness: `scripts/{suite,bench,eval,smoke,run_experiment}.sh`
- Recent campaign records with full reasoning:
  `results/gb10-1988a9714b4e/{Inferact,unsloth}/Qwen3.8-27B-NVFP4/logbook.md`
- Upstream dossier: `research/upstream/vllm-43885-gb10-wedge.md`
