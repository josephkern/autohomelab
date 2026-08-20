# AGENTS.md — operating guide for autohomelab

The contract for any agent (or human) working in this repo. `CLAUDE.md` symlinks here.

**Separation of concerns:**
- **This file (AGENTS.md / CLAUDE.md) is the REFERENCE** — rules, architecture, results schema &
  naming, the gate *definitions*, conventions, hardware/lab notes, pending follow-ups. Ambient
  knowledge: *how things work, why, and what we've learned*.
- **[program.md](program.md) is the executable PLAYBOOK** — the step-by-step procedure to run a
  campaign for a model. To do work: *"read program.md, then execute for `<HFName/HFModel>`."*

Definitions live here; procedure lives there (it references this file rather than restating it).
The **Lab notes** at the bottom are a living log — keep them updated as you learn things.

## What this project is

A portable LLM-serving benchmark + autotuner for NVIDIA hardware that produces a **validated,
optimized vLLM serve config** per model. A promoted `_final.sh` must clear **three gates** (see
[docs/validation.md](docs/validation.md)): **works** (functional smoke), **good** (lm-eval accuracy
within tolerance), **fast** (tok/s @ 1/16/32 via GuideLLM — the tuned objective). Hardware is a
**probed input**; every result is keyed by a hardware fingerprint. See [README](README.md), [docs/](docs/).

## Hard rules (charter)

1. **Reproducibility is paramount.** Pin releases by version *and* digest. No nightlies as the
   authority (a digest snapshot of a nightly is acceptable if pinned). The pinned image lives in
   the runbook (see below).
2. **Benchmarking = tok/s via GuideLLM**, `--profile concurrent`, **per-level isolation** (one
   call per level). Concurrency columns are fixed at 1/4/8/16/32, but the **routine matrix is lean
   — `LEVELS_SET=1,16`** (c1 = cheap crash/latency sentinel; **c16 = the tuning objective**, since
   the throughput knobs only move batched numbers, not c1). Run the **full `1,4,8,16,32`** sweep
   periodically for characterization. (Empirically on GB10: chat still scales at c32 (+47% vs c16);
   coder saturates by c16.)
3. **Every logbook entry records the full stack**: driver, firmware, CUDA, image digest, vLLM
   version, GuideLLM version, model revision, runbook.
4. **Helper scripts are `bash`** (system) **or `python` via `uv`/`uvx`**. No global pip, no other
   languages.
5. **`.env` and raw `results/**/data/` are never committed.**
6. **Repeatable process** — generate config from the probe rather than hardcoding.

## The four layers

- **Probe** (`scripts/probe.sh`) → `results/<node_fp>/node_profile.json` + a stable fingerprint.
- **Backend** (`backends/<name>/adapter.sh`) → launches a server from a runbook, exposes an
  OpenAI endpoint. Contract: [backends/adapter.md](backends/adapter.md). vLLM first.
- **Bench** (`scripts/bench.sh`) → GuideLLM sweep → raw bundle + one `results.tsv` row.
- **Tune** (`program.md` loop) → mutate the runbook to maximize tok/s; keep or drop a *config* by
  the median of N=3 valid rows. That verdict lives in `run_experiment.sh`'s `MEDIAN` line,
  `tune_status.py`'s ranking and the campaign `logbook.md` — **never in a row's `status`** (see
  "Status vocabulary": `keep` is retired, and `discard` is a §7 adjudication, not a loop output).

**HOST-PROCESS backends (GGUF).** Some engines are native host processes, not Docker images with an
adapter — currently **ds4** (antirez "DwarfStar", DeepSeek-V4 arch only) and **llama.cpp** (broad
GGUF arch coverage). They keep the same *results contract* but bypass the adapter layer, so:
serve with a hand-authored `launchers/<ENGINE>-<org>_<model>.sh` instead of `serve.sh`; bench with
the engine's `scripts/bench_<engine>.sh` sibling (same GuideLLM invocation, same `results.tsv`
columns, `backend=<engine>@<git-short-sha>` — pinned by **git sha**, since there is no image digest);
and drive Gates 1–2 through a **runbook stub** (`<launcher>.smoke-runbook.sh`) that carries just
`MODEL`/`SERVED_NAME`/`PROCESSOR`+`TOKENIZER` and parser MARKERS. **`suite.sh` cannot drive these** —
it calls the vLLM `serve.sh` — so run smoke/eval/bench individually. `promote.sh` likewise doesn't
apply: the promoted artifact is the launcher itself, with the winning config as its defaults.
GGUF repos ship no `tokenizer.json`, so `PROCESSOR`/`TOKENIZER` must point at the **unquantized
source repo** or GuideLLM synthetic data and lm-eval loglikelihood tasks both break.
Build llama.cpp with `scripts/build_llamacpp.sh` (CUDA, sm_121 explicit).

**Their `config_hash` is `hp3-<8 hex>`, computed from the SERVED PROCESS** (`scripts/lib/hostcfg.sh`,
20260820) — not from the stub, and not from a git SHA of a source tree. A vLLM runbook *is* the
config, so `sha256sum <runbook>` is honest; a host launcher leaves the gates nothing to hash but the
`.smoke-runbook.sh` stub, so **every ds4 config hashed to the same `10b02344`**. The `hp3` document
is: the process's **argv** read NUL-safely from `/proc/<pid>/cmdline` (repeated flags carry an
occurrence ordinal — llama.cpp's `-ot` is first-match-wins, so two orderings are two offload
layouts), the **tuning environment** the cmdline never sees (`DS4_DSPARK_*`/`DS4_MTP_*`,
`LLAMA_*`/`GGML_*`), the **running binary by content** through `/proc/<pid>/exe`, and the scheme's
own parameters. A value that is an existing readable file is identified by **content**
(`file:<size>:<16 hex over the first and last 4 MiB>`), never by basename — the earlier scheme
reduced every path-looking value to its basename, so `snapshots/rev-AAAA/model.gguf` and
`snapshots/rev-BBBB/model.gguf` collided. That is exactly the layout `huggingface-cli download`
produces and exactly the checkpoint-refresh axis of the ds4 round-3b campaign (the two GGUFs share
a basename and differ only in content), and it also mangled non-paths: a
`--chat-template-kwargs '{"a": "x/y"}'` blob basenamed to nonsense. `--host`/`--port`/`--log-file`
are dropped with their values, so
benching the same config on `:8001` does not mint a new identity. **`eval.sh` computes the same
identity from the same process**, so a host config's Gate-2 row and its Gate-3 rows finally join;
when no known engine is serving the port it writes **`stub-<8 hex>`**, labelled and warned about,
because "we could not identify the engine" is its own claim and must not be groupable with an
`hp3-` row. The `<engine>@<git-short-sha>` string still lives in the `backend` column, where it is
provenance rather than identity. The prefix is deliberate: 315 committed rows carry the old bare-hex
semantics and none was rewritten. Acceptance: `scripts/hostcfg_selftest.sh` (**108 checks**,
fabricated `/proc` via `AHL_PROC`, no server and no GPU).

## Runbooks are the reproducible unit

`runbooks/<HFOrg>/<Model>/` is **model-centric**. A runbook `.sh` is the *complete* config:
**pinned `VLLM_IMAGE` (by digest) + model + revision + serving flags**, exactly like the
hand-written `~/bin/docker-vllm-*.sh` scripts. The image version is a **per-model tuning
dimension**, so it lives in the runbook, not as one global pin. `backends/vllm/image.lock` is a
validated-image *registry* + the default for new baselines.

- `baseline.sh` is generated by `scripts/gen_baseline.py` from the node profile.
- Tuned variants: copy to `<YYYYMMDD>_<change>_tuned.sh`, change **one** thing, and document the
  **delta in the header** (this is the inline journal). Commit one change at a time.
- `*_final.sh` is the **promoted, fully-validated winner** (passed all three gates) — the canonical
  config to serve. Naming:
  `VLLM-<minor>-<HFORG>_<BASEMODEL>_<QUANT>_final.sh` (e.g. `VLLM-22-RedHatAI_Qwen3-8B_NVFP4_final.sh`).
  Create it with `scripts/promote.sh <winning_tuned.sh> "result note"` when a model's campaign is
  complete. The `*_tuned.sh` experiment files are **kept intact** as the project record (never deleted).
- Runbook vars: `MODEL`, `SERVED_NAME`, `MODEL_REVISION`, `VLLM_IMAGE`,
  `VLLM_ENTRYPOINT_SERVE` (true if the image ENTRYPOINT already runs `vllm serve`),
  `VLLM_FLAGS=( … )`, optional `VLLM_ENV=( "K=V" … )`.

## Results model (autoresearch-adapted)

Per **(node, model)** under `results/<node_fp>/<org>/<model>/`:

- **`results.tsv`** — throughput journal, one row per (run, shape). Committed.
- **`accuracy.tsv`** — Gate-2 journal, one row per lm-eval call. Committed. **16 columns**
  (docs/validity-contract.md **A9**, 20260819 — was 12). The four new ones — `conc samples validity
  status` — are **appended**, so the long-standing positional reads (`$5` config_hash, `$10` scores)
  still work:

  ```
  run_id  commit  node_fp  model  config_hash  script  suite  tasks  limit  scores  data  think
  conc  samples  validity  status
  ```

  | column | meaning |
  |---|---|
  | `run_id` | `<UTC YYYYmmdd-HHMMSS>-eval`; also the `data/` bundle directory name |
  | `commit` · `node_fp` · `model` · `config_hash` · `script` | same provenance quintet as `results.tsv` — including the host-process `hp3-<8 hex>` / `stub-<8 hex>` identity, so a Gate-2 row and a Gate-3 row for one launcher config now carry the *same* `config_hash` and can be joined ("HOST-PROCESS backends" above) |
  | `suite` | `general` / `resistant` / `math` / … — which task set was asked for |
  | `tasks` | the lm-eval task list actually run, comma-joined |
  | `limit` | `LIMIT` per task, or `full` |
  | `scores` | `task=score` (percent), `;`-joined. **Never rewritten** — the historical text is the record; the migration recomputes it and reports divergence instead (every migrated row reproduced byte-exact) |
  | `data` | bundle path relative to the repo root (gitignored content) |
  | `think` | `on`/`off` — disambiguates rows that otherwise contradict each other (35B gsm8k `=42` think-on vs `=90` think-off) |
  | `conc` | the concurrency the eval ran at. Backfilled **from each bundle's own `config.model_args.num_concurrent`**, never stamped or assumed: of the 79 rows, 75 are c16, **two ds4 rows really ran at c4**, and the two 20260820 rows are the deliberate c1/c32 pair — which refutes the standing "every accuracy row is c16" claim (see the follow-up) |
  | `samples` | `task=effective/requested`, from the bundle's own `n-samples`, `;`-joined. The denominator is computed **per leaf subtask**, never as a flat `limit`: `mmlu --limit 100` legitimately requests **5,700** docs (57 subtasks × 100) out of 14,042. This is the evidence for the completeness check, so a later reader can re-derive the verdict under a different threshold |
  | `validity` | Gate-2 verdict tokens, **task-tagged** the way Gate-3 tokens are level-tagged (`nonfinite@mmlu`, `short_sample@gsm8k`), `+`-joined, `ok` when clean, `na` when the rules could not be evaluated (never `ok`) |
  | `status` | the same §6 vocabulary as `results.tsv`, floored by the verdict: `measured` / `suspect` / `void` |

  | token | rule | severity |
  |---|---|---|
  | `no_score` | no results json, unparseable, or the requested task has no metric | fatal |
  | `nonfinite` | the headline metric is `NaN` or +/-`Inf` | fatal |
  | `short_sample` | `effective < AHL_EVAL_MIN_SAMPLE_FRAC * requested` (**0.99**) | fatal |
  | `zero_score` | the headline metric is exactly `0.0` | suspect |
  | `no_samples` | the bundle carries no `n-samples`, so the check could not run — fail closed | suspect |

  Rules live once, in `scripts/eval_validity.py`; `eval.sh` scores its own bundle before writing
  the row and exits **4** when the result is not citable, on the repo-wide ladder 3 > 4 > 1 > 0.
  `suite.sh`/`validate.sh` latch that and re-read the row, so the report and the exit code cannot
  disagree. **Verified against §0 defect (c):** a `nan` score, a 37-of-14,042 run and a missing
  results file each now record a row and **fail** Gate 2 — all three previously reported **PASS**,
  because only `lm_eval`'s exit code was consulted. Acceptance suite:
  `scripts/eval_validity_selftest.sh` (**96 checks**, synthetic bundles, no GPU) — which includes
  **execution traces** proving every Gate-2 branch is reachable for all four runbook variants
  (neither / reasoning / spec-decode / **both**). Migrate a legacy journal with
  `scripts/migrate_accuracy_tsv.py --write` (idempotent; `eval.sh` calls it automatically when it
  meets a 12-column file).
  **What this predicate deliberately does NOT do: compare a score to a reference or to a floor.**
  It answers "is this a number?", never "is this number good?" — the value-side reasoning is a
  *relative* regression check against a matched-settings reference (docs/validation.md → Gate 2),
  and what a given task can actually resolve is arithmetic, not taste (see the `LIMIT` note below
  and `research/review/POWER-analysis.md`). Residual gaps, recorded rather than papered over:
  lm-eval publishes no per-request error count, so there is no `errored`-style visibility on this
  gate; a zero-token generation is detectable only through its 0.0 score; and — worse than either —
  **lm-eval substitutes a placeholder for a null completion and counts the item as answered**, so a
  serve returning empty content on a fifth of the set still reports `samples=100/100` with a finite
  score and passes `validity=ok` (measured live 20260820, see the lab note). All three need
  `--log_samples`.

  **`LIMIT` is PER LEAF SUBTASK, and this repo got the arithmetic wrong for months.** `lm_eval
  --limit L` applies to each leaf, not to the task group, and it takes the **first** L docs of each
  leaf's split — a deterministic prefix, so every run at a given limit scores the identical items.
  (Which is also why `LIMIT=100` is **not** a random subsample: on the one config measured both
  ways, mmlu 73.25@100 vs 70.99@full and gsm8k 92.0 vs 87.64 — the first docs of each leaf are
  systematically easier, so an in-loop number and a finalize number for the same config are not
  interchangeable.) Therefore at `LIMIT=100`:

  | task | leaves | effective n | binomial SE at its typical p | lm-eval's own recorded `acc_stderr` |
  |---|---|---|---|---|
  | `gsm8k` | 1 | **100** | 2.71 pt @ p=.92 | 2.88 pt strict / 1.97 flexible (33 bundles) |
  | `mmlu_pro` | 14 | **1,400** | 1.22 pt @ p=.70 | **1.20 pt** (14 bundles) |
  | `mmlu` | 57 | **5,700** | 0.51 pt @ p=.82 | **0.49 pt** (24 bundles) |

  The right-hand column is not a derivation — it is what lm-eval wrote into every bundle we kept,
  and the `samples` column above shows the same thing (`mmlu=5700/5700`). **The old "±4.3 points at
  `LIMIT=100`" figure is right for `gsm8k` and wrong for `mmlu` by 7.6× in n, i.e. 2.8× in SE**, and
  the follow-ups that rested on it are corrected below. Consequence in both directions: the gate is
  *better* than believed on the task it actually computes, and the historical spreads it called
  noise are **not** explainable as sampling noise.
- **`logbook.md`** — narrative (what was tried/kept/discarded + the environment block). Committed.
- **`SUITE-<cfg>.md`** — the per-config validation report `suite.sh` writes. Committed.
- **`data/<run_id>/`** — raw bundle: `level_c<N>.json` (GuideLLM output, one per level — the
  evidence the validity verdicts are computed from), `level_c<N>.log`, `gpu_metrics.csv`
  (power/temp/util sidecar), `vllm_crash.log` on a wedge. **Gitignored** — which is exactly why
  the validity columns exist: they put the auditable part of the bundle into the committed journal.

### `results.tsv` — 23 columns (tab-separated)

```
run_id  commit  node_fp  model  shape  backend  config_hash  script
load_s  max_s  seed  tps_c1  tps_c4  tps_c8  tps_c16  tps_c32  peak_gb
req_counts  validity  knobs  status  notes  data
```

Binding spec: **[docs/validity-contract.md](docs/validity-contract.md)** §2. The header string and
every validity rule are defined **once**, in `scripts/lib/validity.py`, and consumed from there by
`bench.sh`, `bench_ds4.sh`, `bench_llamacpp.sh` and `aggregate.py` (`scripts/lib/validity.sh` is a
thin bash shim and re-implements nothing). Column order is fixed, no value is ever empty (use
`na`), and no value contains a tab or newline.

| column | meaning |
|---|---|
| `run_id` | `<UTC YYYYmmdd-HHMMSS>-<shape>`; also the `data/` bundle directory name |
| `commit` | repo short SHA at bench time |
| `node_fp` | hardware fingerprint from the probe (`results/<node_fp>/`) |
| `model` | full HF repo id |
| `shape` | workload — `chat(512/256)` (default, the tuning objective) or `coder(4096/1024)` |
| `backend` | `vllm@<ver>(img:sha256:<short>)`; host-process engines use `<engine>@<git-short-sha>` |
| `config_hash` | first 8 hex of `sha256sum <runbook>` — provenance for the exact config. **Host-process backends instead carry `hp3-<8 hex>`**, computed from the served process (`scripts/lib/hostcfg.sh`), or `stub-<8 hex>` when no engine could be identified |
| `script` | runbook path relative to the repo root |
| `load_s` | time-to-healthy recorded by `serve.sh`; `na` if the serve state doesn't match this runbook |
| `max_s` | `MAX_SECONDS` per level actually used — **not** universal, scale it to the model |
| `seed` | `AHL_SEED` (default 42) → identical synthetic prompts across configs, so comparisons are paired |
| `tps_c1 … tps_c32` | GuideLLM `output_tokens_per_second.successful.mean` per level; `na` = level not run, `hang` = the level that wedged |
| `peak_gb` | peak memory; `na` on unified-memory nodes (nvidia-smi can't report it) — falls back to a system-used proxy |
| `req_counts` | per-level request outcome in the order `ok/incomplete/errored`, semicolon-joined, run levels only: `c1:41/0/0;c16:118/4/0`. A level that ran but left no parseable JSON renders `c16:na`; the whole field is `na` when no bundle survives. This is what makes a number auditable without the raw bundle |
| `validity` | `ok`, or a `+`-joined list of **level-tagged** verdict tokens: `low_sample@c1+survivorship@c16` (table below) |
| `knobs` | the full effective knob set resolved at run time, `k=v` comma-joined, **list values separated by `|`** so a naive `split(",")` is always right: `levels=1\|16,max_s=180,seed=42,prompt=512,output=256,stall=90,ltimeout=480,gllm=0.6.0`. A baseline at `MAX_SECONDS=600` and a finalize at the 180 default used to be indistinguishable in the journal |
| `status` | see the status vocabulary below |
| `notes` | free text: `hang@c<N>` on a wedge, the `thermal=…` sidecar summary, plus any `NOTES=` |
| `data` | bundle path relative to the repo root (gitignored content) |

`scripts/aggregate.py` concatenates every `results.tsv` for cross-node comparison, and **filters
`void`/`suspect`/`crash` out of its default view**.

**An interrupted bench still leaves a row.** `bench.sh` used to emit its row only after the level
loop, so a Ctrl-C, a session limit, a `kill` or a reboot mid-shape left a `data/<run_id>/` bundle
full of real `level_c*.json` evidence that **no row referenced** — invisible to `aggregate.py`, to
the audit and to every gate, because the committed journal is the record and the bundle is
gitignored. All three benchers now trap and record a partial row (`status=suspect`, or `void` under
a fatal floor, or `crash` if the shape had already wedged), carrying `incomplete_run` in `validity`.
`SIGKILL`, a kernel OOM-kill and a power cut are still beyond a trap, and two orphans already on
disk predate it: **`uv run scripts/reconcile_bundles.py`** walks the tree, finds bundles nothing
points at, scores them through the library and — with `--write` — appends one plainly-marked
reconstructed row each (`status` never `measured`, provenance columns `na`, never guessed). It is a
dry run by default and only ever appends.

### Validity verdicts

Computed per row from the per-level GuideLLM JSON; **fatal** verdicts void a row, **suspect**
verdicts flag it. Binding rules and thresholds: [docs/validity-contract.md](docs/validity-contract.md)
§3–4 (**v1.3** — read its amendment blocks and the closing v1.2-status and v1.3 sections, which win
over anything earlier in that file); the reasoning a human applies by hand is in
[docs/validation.md](docs/validation.md) (Gate 3); the pass over the whole published record is
`research/review/AUDIT-measurement-validity.md`.

**Tokens carry the level they refer to**: `low_sample@c1`, `no_data@c32`, `survivorship@c16`. Only
`ok`, `nonmonotonic` and `incomplete_run` are row-wide and untagged. This matters operationally — a
thin c1 sentinel no longer condemns the c16 objective the campaign is actually tuning; **300 of the
317 published rows (94.6%) carry no token tagged at c16.** Gate on the level you cite.

| token | rule | severity |
|---|---|---|
| `ok` | all checks pass | — |
| `no_data` | `successful < AHL_MIN_DATA` (**5**), or `level_c<N>.json` missing/unparseable | fatal |
| `low_sample` | `successful < max(AHL_MIN_DATA, min(20, 4*level))` | suspect |
| `over_roofline` | a level's tok/s exceeds the physical ceiling (bandwidth roofline, SAFETY **3.0**) | fatal |
| `no_output` | `successful > 0` but tok/s is null, non-finite or `<= 0` — the **floor** under the roofline's ceiling | fatal |
| `survivorship` | `successful > 0` and `incomplete > successful` — a **majority** of the work started was discarded, so the published mean averages a minority of it | suspect |
| `nonmonotonic` | a run level >**10%** below the **immediately preceding** run level (adjacent-only) | suspect |
| `incomplete_run` | the sweep was **cut short** — the process was signalled or the shape never finished. **Row-wide and untagged**, so it is non-citable at *every* level scope | suspect |
| `errored` | `errored` is 10–50% of `successful + errored` | suspect |
| `errored_fatal` | `errored` is **above 50%** — the endpoint is refusing, not serving | fatal |
| `na` | the rules could not be evaluated (no bundle) — **never `ok`** | — |

`no_data` and `low_sample` are mutually exclusive **per level**. A level counts as **run** if the
journal published a cell **or** a bundle file exists (the union); unrun levels are skipped, never
scored as zero; a hung level is scored and its token names it. The published run-level list wins
over a directory listing, so a stale `level_c8.json` from a previous shape is ignored.

**Why `incomplete_run` is ROW-WIDE, and the hole it closes.** An interrupted sweep produces real
numbers for the levels that landed, so voiding them would be the mirror-image lie; but the run as a
whole never completed, and that is a property of the *run*, not of one concurrency level. It has to
be row-wide for a second reason, which is the actual defect it fixes: **`citability.classify_row`
ignores `status` at level scope** (deliberately — a `status` downgrade caused by a token at another
level must not condemn the level you cite), so `status=suspect` alone had *no consumer-visible
effect* on an interrupted row, and the promotion gate reported it as `suspect=0`. A row-wide token
is the only kind that survives a level-scoped reading. Suspect rather than fatal: the completed
levels **are** data, they are simply not citable until a human adjudicates under contract §7. A
fatal verdict still outranks it through the status floor.

**Why `low_sample` is a bare request floor — and why it was a token budget for one day
(v1.1 -> v1.2 A1).** The rule has been wrong twice, and both wrong versions had a plausible story,
so the measurements are recorded here rather than the story.

- **v1.0, a flat 20-request floor.** Fired on 55% of the historical corpus; 160 of 181 flagged
  bundles offended only at c1 — where the sample count is `MAX_SECONDS / per-request latency`, i.e.
  arithmetic, not operator error. A detector that flags the majority of good rows is a detector
  nobody reads.
- **v1.1, a 2048-token budget (`AHL_MIN_TOKENS`) OR the per-level request floor.** The premise was
  that tokens generated predicts reproducibility where request count does not. **Two verifiers
  refuted it independently, by different methods, and it was DELETED.** The clause fired *alone* on
  exactly **3 of 693 bundles**, all three the same replicate bracket — whose measured CV of
  **0.59–0.70%** makes it *more* reproducible than most brackets on this node. Three false
  positives, zero true positives. Banding CV by token budget runs the wrong way (0.70% under 2048
  vs 1.28% above 20k) and the correlation with measured reproducibility is **r = -0.006**. Worse,
  a coder completion carries ~1000 output tokens, so **3 requests clear a 2048 budget** — the
  clause would have **APPROVED 10 of the 15 genuinely starved levels** in the corpus. It did not
  merely fail to detect starvation, it approved it. `AHL_MIN_DATA` was doing all the work.
- **What survives from v1.1:** its premise that *request count* does not predict reproducibility is
  confirmed (median CV **0.39% at n<10**, **1.42% at 10≤n<20**, **0.56% at 20≤n<50**). The
  inference that *tokens* do was wrong. **Neither predicts it on this corpus** — which is why the
  floor is now deliberately a structural minimum, not a precision estimate.

**Corollary, and a test pins it: `low_sample` can never fire at c1.** The floor is
`max(5, min(20, 4*1)) = 5 = AHL_MIN_DATA`, and `no_data` claims everything below 5 first, so a c1
stage is either `no_data` or clean. `coder` characterization is likewise not suspect by
construction — a `coder(4096/1024)` level legitimately completes few requests, and the floor at c16
is 20 regardless of how many tokens each one carried.

**Why `survivorship` is a MAJORITY-discard rule, and what it does not catch (v1.1 -> v1.2 A2, then
re-adjudicated after measuring).** GuideLLM's `successful.mean` silently drops the requests still in
flight at stage end, and those are the SLOW ones, so the reported mean is the mean of the faster
part — a directional bias, not noise. Three forms were written:

- **v1.1: `incomplete >= successful`, justified as a general bias detector.** It is not one: that
  condition is arithmetically `successful <= level` (the in-flight set at stage end is ~`level`), so
  it cannot fire below a **50%** discard rate, while its own justification cited 32.4% (coder c16)
  and 46.2% (coder c32). 18 level-instances discarding 30–48% graded `ok`.
- **v1.2 A2 as written: `incomplete > level` AND discard > 30%.** **Unsatisfiable.** GuideLLM
  bounds its in-flight set by the concurrency level (88.8% of levels sit at exactly `level-1`, max
  ratio 1.000), so the rule fired **zero times on 690 levels** and missed all 53 level-instances it
  was written to catch.
- **Shipped: `successful > 0 and incomplete > successful`** (`ok > 0 and incomplete > c.ok` in the
  library, where `ok` is the successful count). The alternative was measured first: a 30% discard
  threshold flags **19 of 23 coder rows** (>40% flags 13, >50% flags 10). A verdict that fires on
  83% of a shape is a claim about the measurement METHOD, not a per-row defect, and flag fatigue is
  the failure this layer exists to avoid.
- **Stated, not implied: the systemic 30–48% coder discard at high concurrency is REAL and no
  verdict catches it.** It is a methodology limitation of the coder shape at these stage times, and
  it lives in the GuideLLM lab note below and in `research/review/AUDIT-measurement-validity.md`
  rather than in a `validity` cell. `AHL_DISCARD_TOL` (0.30) is retained for the audit's reporting
  only — it is not the rule.

Sample adequacy is still the primary detector; monotonicity is secondary and deliberately loose,
because `c8 > c16` within noise is a legitimate result on a bandwidth-bound box.

### Status vocabulary — FIVE words (contract v1.3, 20260820)

`measured` · `discard` · `crash` · `suspect` · `void`. **`keep` is RETIRED.**

| status | means |
|---|---|
| `measured` | **the invariants passed** — valid data, not yet judged. It no longer means merely "a row exists" |
| `discard` | an **orchestrator adjudication under contract §7**, applied to the journal *after* the fact, for a row the invariants cannot fault but a human can. Must be signed `adjudicated@YYYYMMDD who: reason` in `notes` (reason ≥ 12 chars) |
| `crash` | engine wedge/hang; the offending level's tok/s cell is `hang`. **Non-valid for every consumer** |
| `suspect` | measured, but an invariant questions it — **not citable** without an adjudication recorded in the logbook |
| `void` | **not data.** Must not be cited, medianed, plotted, or promoted on |

**Why `keep` went, and why it is REFUSED rather than merely undocumented.** It was never written:
**0 of 317 rows**, across 15 campaigns and every backend. Two structural reasons, either of which
is sufficient. **Wrong grain** — a keep verdict is a statement about a *config*, decided on the
median of N=3 benches; `status` is a property of *one row*, and there is no row that is "the kept
one". **Wrong time** — `bench.sh` writes each row as that row finishes, and §7 forbids rewriting a
published row afterwards, so at the only moment the column can be written the comparison that would
justify `keep` has not happened yet. `STATUS_VOCAB` is now five words, `check_status()` (and
therefore `apply_status()`) raises on `keep` with its retirement notice, and **both runners reject
`STATUS=keep` before serving anything** (exit **2**, the usage rung — a refused invocation measured
nothing and is not a result). The decision lives where it always actually lived: the `MEDIAN` line,
`tune_status.py`'s ranking, and `logbook.md`.

**Why `discard` stayed, and what it is NOT.** It is not a bench-time verdict and never was: the
documentation used to say keep/discard were "set via `STATUS=` at bench time", and **that mechanism
does not exist** — `bench_ds4.sh` and `bench_llamacpp.sh` hard-code `status="measured"` and never
read `$STATUS` at all, and all six historical `discard` values were applied by later adjudication
commits. It stays because the class of row only a human can fault is non-empty and unrecoverable
from `validity`. The row that settles it: **`20260809-183024-chat`** (cfg `653a8d9c`, the FF711
`NP=32` bench) carries only `survivorship@c32` and classifies **valid at c16 — the tuning
objective**. It is rejected because `NP=32 × CTX_PER_SLOT=12288` drove total context to 393,216
(~25 GiB KV) and over-committed unified memory into swap, and because it changes two things at once.
**No invariant can see swap** — it leaves no trace in a GuideLLM level json. Contamination and
confounded design are the same shape. So `discard` is signed, dated and greppable:

```
grep -h 'adjudicated@' results/*/*/*/results.tsv
python3 scripts/lib/validity.py status --tsv results/*/*/*/results.tsv   # 0 clean, 4 offenders
```

A §7 adjudication may also leave a `discard` standing over a **void** floor — five of the six rows
do — and the stamp is what records that the human saw the floor and ruled anyway. `apply_status()`
still downgrades a hand-set `discard` on the WRITE path; the §7 hand adjudication is the deliberate
exception, which is why the two can disagree in the journal without either being a defect.

### Enforcement — record and flag, exit 4

A failing run is **still written** to `results.tsv`: the evidence must survive in the committed
journal, not only in the gitignored bundle. What changes is the verdict, not the existence of the row.

- Any fatal verdict → `status=void`; any suspect verdict → `status=suspect`; otherwise the caller's
  status stands.
- **`crash` outranks validity** — an already-`crash` row keeps `status=crash` and carries its
  verdict in `validity` — and `crash` is **non-valid for every consumer**.
- **Consumers filter on `validity`, never on `status` alone.** A `crash` row carrying
  `over_roofline` would sail through a status-only filter; that is exactly the class of hole this
  layer exists to close.
- `bench.sh` exits **4** on *any* non-`ok` verdict — **including a `suspect` on its own** — and **3**
  on crash; crash wins if both occur; 0 = clean. **Exit 4 means "the row is written but not
  citable — continue", never "abort"**: a caller that treats it as a fatal error loses the rest of
  the sweep and the evidence it was about to record.
- Downstream refuses to launder a bad row. **One classifier answers "may this row be cited?" for
  every consumer: `scripts/citability.py`** (`classify_row`, built on `lib/validity.py`'s
  `verdict_base`/`parse_validity_pairs`). It previously existed as five hand-copied `def classify`
  bodies inside shell heredocs, and all five shared the same three bugs — they matched
  level-TAGGED tokens against a bare `{'no_data','over_roofline'}` set (so **no fatal row ever
  graded `void`**; 15 committed rows were mislabelled), they dropped `na` alongside `ok` (so an
  unevaluable row read as citable), and `crash` reached "citable" whenever `validity` was `ok`/`na`.
  Consumers now: `promote.sh` gates the promotion (below), `run_experiment.sh` will not median over
  non-citable rows and publishes `cite=ok|partial|insufficient|no_valid_data|error` plus
  `otherlvl=` on its `MEDIAN` line, `aggregate.py`/`tune_status.py` hide void **and** suspect **and
  crash** by default (`--include-void`, `--include-suspect`, `--include-crash`, `--validity
  <token>` to look anyway). Operator procedure: program.md → "Invalid runs".
- **`promote.sh` gates the OBJECTIVE, not every row that shares the config_hash.** A promotion
  cites one number — chat-shape median c16 — and contract §3 says consumers gate on the level
  they cite. So the supporting rows split: **objective rows** (chat, c16 actually run) must include
  at least one citable at c16, and any objective row that is *fatal* at c16 (`no_data@c16`,
  `over_roofline@c16`) or a `crash` blocks absolutely; **every other row** (other shape, or one
  that never ran c16) is reported on stderr and written into the promoted artifact's header, but
  does not block. Blocking on all of them refused 16 of 92 config groups — 12 of those over rows
  the promotion never quotes, typically a starved *coder* full-sweep beside four clean chat rows —
  and a gate that wrong is a gate operators switch off. Knobs: `AHL_PROMOTE_SHAPE` (default
  `chat`), `AHL_PROMOTE_LEVEL` (default `16`, or `none` for a row-wide gate). If a config never ran
  the objective level the gate falls back to the highest level it did run, and says so — the ds4 /
  llama.cpp launchers bench c1 only.
  **Read the gate for what it does, not for the older sentence.** Contract §5 still carries the
  v1.0 line *"`promote.sh` refuses void/suspect supporting rows"*; that has been false since the
  level-scoped gate replaced it. The gate blocks on **fatal-at-the-objective or crash**, or on
  having no citable objective row at all — `blocked = any fatal or n_valid == 0`. A *suspect*
  objective row is counted and reported (`suspect=N` in the summary line) but does **not** block on
  its own while another objective row is citable. That is deliberate, and it is exactly why an
  interrupted row needed the row-wide `incomplete_run` token rather than `status=suspect`: at level
  scope the classifier does not look at `status`, so the gate was reporting `suspect=0` on a sweep
  that never finished. Do not restate the §5 sentence anywhere.
- **`AHL_PROMOTE_OVERRIDE` is a justification, not a flag** — `promote.sh` rejects `1`/`yes`/`force`
  and anything under 12 characters, and writes the text permanently into the promoted `_final.sh`,
  where it is greppable (`grep -l AHL_PROMOTION_OVERRIDE runbooks/*/*/*_final.sh`). Overriding is a
  human act that leaves a signature; there is deliberately no equivalent in `run_experiment.sh`,
  because a tuning loop must not self-authorize. **The signature is a COMMENT, never an
  assignment**: `_final.sh` is `source`d by serve.sh/bench.sh, and the old
  `AHL_PROMOTION_OVERRIDE="<operator text>"` line executed any `$(...)` in the justification at
  *serve* time (verified, not theoretical — same for `$USER` and the free-text result note).
- **Exit-code precedence, repo-wide: `3` (crash) > `4` (not citable) > `1` (gate failure) > `0`.**
  Codes latch upward and are never overwritten, so a smoke failure cannot mask a Gate-3 row that is
  not data. `suite.sh` and `validate.sh` both used to report the quieter `1` in that case.
  `run_experiment.sh`'s `1` means strictly *pre-measurement* (serve/smoke): a failure of the median
  summarizer itself now exits **4** with `cite=error`, because the bench rows were written and
  saying "1" told the caller nothing had been measured.
- **`tests/run.sh`** is the acceptance suite for this layer (**279 tests**, ~45 s, stdlib only, no
  GPU or network). Run it with `AHL_TEST_STRICT=1` — a SKIP means "this contract rule was not
  checked", not "it passed". **`tests/mutate.sh`** is the second half of the gate: it copies the
  repo per mutation, breaks one rule or one enforcement link, and expects the suite to go RED.
  **38 mutations, 0 survivors.** A rule with no mutation that turns the suite red is an untested
  rule — mutation testing of the v1.1 suite found **16 survivors** with 121/121 green, including
  every enforcement path. **`scripts/citability_selftest.sh`** is the REACHABILITY companion
  (**102 checks**):
  it runs the real `promote.sh`/`run_experiment*.sh`/`suite.sh`/`validate.sh` inside a throwaway
  repo whose `serve.sh`/`smoke.sh`/`eval.sh`/`bench*.sh` are stubs returning scripted exit codes,
  and asserts on which branch actually executed — because the scar in this repo (see the
  reasoning × spec-decode bug) is a *correct condition in an unreachable branch*, which no
  assertion about the condition can catch. Also hermetic: no docker, server, GPU or lm-eval.
  Four more hermetic selftests sit beside them, each owning a layer this suite does not:
  **`scripts/eval_validity_selftest.sh`** (Gate 2, **96 checks**),
  **`scripts/hostcfg_selftest.sh`** (host-process identity, **108 checks**, fabricated `/proc`),
  **`scripts/eval_private_selftest.sh`** (tier-4 private set, **261 checks**) and
  **`scripts/power_selftest.sh`** (**77 CLI checks** — **71** in a worktree, where the gitignored
  bundles are absent; point `AHL_POWER_DATA_ROOT` at the main checkout for the other six — plus 68
  numeric self-checks inside `power.py selftest`).

### Schema history — and why this section is normative

This section documented a **16-column** row long after it had become **20** (`load_s`, `max_s`,
`seed` were added to `bench.sh`, `bench_ds4.sh`, `bench_llamacpp.sh` and `aggregate.py` without a
doc change), and it went to **23** on 20260819 with `req_counts`/`validity`/`knobs`. Four files
hard-coded the header string and all four agreed with each other; the only disagreeing copy was the
one humans and agents read. That is itself evidence for issue #1 §1 — **the schema changed and the
reference did not follow**, silently, for months. The header now lives in one place
(`scripts/lib/validity.py`); when it changes, this table changes in the same commit.

Historical rows (**317** across 15 campaigns as of 20260820 — 315 after the ctx merge, plus the two
rows the 20260820 live-hardware validation added; the review issue's 313 predates both) get
`req_counts`/`validity`/`knobs` backfilled where a retained bundle allows it, but **historical
`status` values are not rewritten in bulk** — several are already cited in logbooks, so they are
adjudicated row by row (contract §7). **6 rows are permanently unauditable** — their bundles are
gone, and that is the hard ceiling on how much of this project's record can ever be verified.

**The corpus as of 20260820** (recompute it, never copy it: `awk -F'\t' 'FNR>1&&NF>1{print $(NF-2)}'
results/*/*/*/results.tsv | sort | uniq -c`):

| axis | breakdown |
|---|---|
| `status` | **284 `measured` · 12 `crash` · 8 `suspect` · 7 `void` · 6 `discard`** = 317 |
| `validity` floor | 284 `ok` · 9 suspect-floor · 23 void-floor · 1 `na` (which also floors suspect) |
| level scoping | 300 of 317 (94.6%) carry no token tagged at c16 |
| `accuracy.tsv` | **79 rows** — 76 `measured`, 3 `suspect` (`zero_score@gsm8k`) |

**The adjudication is complete: 0 rows now disagree with their verdict.** Every void-floor row is
`void`, `crash` or a signed §7 `discard`; every suspect-floor row is `suspect` or better-ruled; and
`python3 scripts/lib/validity.py status --tsv results/*/*/*/results.tsv` exits 0. The worklist that
used to live here — "13 rows where the invariants dispute the status and nobody has ruled" — is
empty. Note that `keep` was **never** written to a row (0 of 317), which is why it is retired.

## Standard test suite

The canonical battery a model must pass, run by **`scripts/suite.sh <runbook>`** (one serve session,
load amortized; tears down at the end; writes `SUITE-<cfg>.md` + results.tsv/accuracy.tsv rows). Run
it at **baseline** (program.md §1) and at **finalize** (`FULL=1 scripts/suite.sh <winner>`, §3). The
tuning **loop stays lean** (chat c1/c16, N=3 via `run_experiment.sh`) — never run the full suite
per-candidate.

- **Gate 1 — works** (`smoke.sh`): functional 4-check (chat / JSON / tool-call / reasoning routing).
- **Gate 2 — good** (`eval.sh`): **validity is a precondition, not a post-check** (contract A9):
  a score that is `nan`, computed over fewer samples than were requested, missing, or exactly
  `0.0` is not a Gate-2 result at all — `eval.sh` exits **4** and the row records why
  (`validity`/`samples`/`conc`; see the accuracy.tsv schema above). Tasks:
  `general` (gsm8k, mmlu — the in-loop quality reference) **and**
  `resistant` (default **`mmlu_pro`**, harder/less-memorized, tier 2). `gpqa_diamond_zeroshot` is a
  **gated** HF dataset (`Idavidrein/gpqa`) — request access, then opt in with
  `TASKS=mmlu_pro,gpqa_diamond_zeroshot`. `LIMIT=100` for the in-loop reference; `FULL=1` (no cap) at
  finalize. For **competition-math / long-CoT** models (e.g. VibeThinker) use the **`math` suite**
  (`aime24,aime25` — they PREFER `\boxed{}` extraction; minerva_math500/hendrycks_math500 do NOT and
  score ~0 on `\boxed` output). Long-CoT eval needs: **temp 1.0** (`GEN_KWARGS do_sample=True`; greedy
  loops on RL-reasoners), large **`GEN_TOKS`** (auto-32768) + **`EVAL_TIMEOUT`** (default 1800s; 32K-tok
  gens blow lm-eval's 300s default), and the **chat endpoint** (`THINK=off` → apply_chat_template).
  Tier-3 time-gated (`eval_live.sh` / LiveBench) and the **tier-4 private held-out set**
  (`scripts/eval_private.sh`, [docs/private-eval.md](docs/private-eval.md) — the mechanism is built
  and self-tested, no real items authored yet) remain opt-in, not in the standard suite.
  **Which task can resolve what is arithmetic, not preference:** `gsm8k@LIMIT=100` really is n=100
  and detects ~14-point breakage and nothing finer; `mmlu@LIMIT=100` is n=**5,700** and
  `mmlu_pro@LIMIT=100` is n=1,400, because `--limit` applies per leaf subtask (see the
  accuracy.tsv `LIMIT` note above, and `research/review/POWER-analysis.md`). `eval.sh general`
  already computes both — cite the one whose n supports the claim.
  **Caveat:** standard `mmlu` is
  *loglikelihood*-scored and can be unreliable for some archs (Gemma-4 scored ~41 — BOS/prefix-LM/
  logit-softcapping); cross-check with the *generative* gsm8k + mmlu_pro before trusting it as a gate.
  **Speculative decoding ⊥ loglikelihood — PER MODEL, not universal (corrected 20260820).** The
  failure is real where it was found: a config with `--speculative-config` (MTP/draft) can return
  **NaN prompt_logprobs**, so loglikelihood `mmlu` 400s (`Out of range float values are not JSON
  compliant`) — Nemotron-3-Super MTP final, and the 56,168-request NaN grind below. **But the
  journal holds ELEVEN counter-examples across THREE models**, every one from a runbook carrying a
  live `--speculative-config` and every one recording `mmlu=5700/5700`, `validity=ok`,
  `status=measured` with a normal `acc_stderr` of 0.48–0.54, across vLLM 0.23.0 / 0.24.0 / 0.25.0:
  8 rows on `RedHatAI/Qwen3.6-35B-A3B-NVFP4` (78.19 78.44 77.60 82.82 81.75 82.65 81.79 81.72),
  2 on `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` (81.28 81.32) and 1 on
  `nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4` (83.67). So **probe, do not assume**:
  `TASKS=mmlu LIMIT=2` is 114 items and finishes in seconds — if it returns finite scores,
  `mmlu@5,700` is available for that model. Where the loglikelihood path genuinely is closed, fall
  back to generative gsm8k/mmlu_pro think-off. Spec-decode in vLLM is greedy-lossless, so generative
  scores carry over. *(Re-checking this count: a naive `grep speculative` also matches
  commented-out flags and header prose, which inflates 11 rows to 18 across 7 more runbooks. Strip
  full-line comments before matching — the count depends on the pattern, which is itself the point.)*
  **REASONING × SPEC-DECODE branch-order bug (found + fixed 20260817, Qwen3.8-27B finalize).** suite.sh
  tested `REASONING` and `SPEC` as mutually exclusive `if/elif` with reasoning FIRST, so a runbook that is
  BOTH (reasoning-parser **and** `--speculative-config` — i.e. every promoted reasoning model with MTP)
  fell into the reasoning branch and ran loglikelihood `mmlu` anyway; the spec-decode skip was
  unreachable. Symptom: a full 56,168-request mmlu run (14,042 × 4 choices) grinding out
  `400 Out of range float values are not JSON compliant: nan` per request for over an hour, still
  "progressing" — lm-eval retries and keeps going, so it does NOT abort, and would have reported a score
  computed over whatever subset happened to succeed. Fixed by testing the combination first: for
  reasoning+spec there is NO thinking-ON quality task available (mmlu is the only loglikelihood task and
  spec-decode rules it out), so Gate 2 is entirely the generative gsm8k+mmlu_pro think-off pass.
  **Lesson: confirming a guard's condition fires is not the same as confirming its branch is reachable.**
  This was not a one-off — see the lab note "A CORRECT CONDITION IN AN UNREACHABLE BRANCH" for the
  other two instances and what we now run to catch them.
  **Thinking-OFF generative eval — it is model-dependent, and the direction is NOT consistent.**
  Reasoning models (runbook has `--reasoning-parser`) emit `<think>` CoT on the raw eval path that
  truncates/derails generative tasks: the 35B goes gsm8k **40→90** with thinking off. **But
  `RedHatAI/Qwen3-8B-NVFP4` goes 90→56** — measured live 20260820, same day, same config — with
  **17–19% of items returning null content**, and Gate 2 passed it `validity=ok` because lm-eval
  substitutes a placeholder for a null completion and counts the item as answered, so
  `samples=100/100` and the score is finite. `suite.sh` auto-applies think-off to **every**
  `--reasoning-parser` runbook, so for that model the gate silently substitutes 56 for 90. **Do not
  read this fix as always helping.** Probe the think-off serve (`content` non-empty?) before
  trusting any generative score from it; the predicate cannot see the substitution without
  `--log_samples`. suite.sh auto-detects reasoning runbooks and runs gsm8k + mmlu_pro on a
  **second, thinking-OFF serve**
  (`AHL_THINK_OFF=1` → `--default-chat-template-kwargs '{"enable_thinking": false}'`, evaluated via
  the **chat** endpoint with `THINK=off` since `enable_thinking` only applies to `/v1/chat/completions`,
  not `/v1/completions`); loglikelihood `mmlu` stays on the deployed thinking-ON serve (thinking-agnostic).
  The thinking-off kwargs are **per-model** via `AHL_THINK_OFF_KWARGS` (env or runbook var; default
  `{"enable_thinking": false}`): **NemotronH** generates **zero tokens** from the pre-closed
  `<think></think>` that `enable_thinking=false` renders (gsm8k think-off **0.0**), so its runbook sets
  `AHL_THINK_OFF_KWARGS='{"low_effort": true}'` — NVIDIA's reduced-reasoning knob keeps the working
  `<think>\n` format and lands the answer in `content` (gsm8k **0→62 strict / 95 flexible**). Probe a
  new reasoning arch's think-off serve (`content` non-empty?) before trusting its generative scores.
- **Gate 3 — fast** (`bench.sh`): full `1,4,8,16,32` GuideLLM sweep in **both** throughput shapes —
  `chat(512/256)` (the tuning objective, median c16) **and** `coder(4096/1024)` (long-context
  characterization). Per-level isolation + watchdog (crash-safe); suite re-serves if a wedge tore
  the container down. **Validity is a precondition, not a post-check:** a tok/s number whose row
  comes back `void` (or unadjudicated `suspect`) is not a Gate-3 result at all — see
  [docs/validation.md](docs/validation.md) Gate 3 for the verdicts, the roofline, and how to apply
  both by hand.

Suite knobs: `FULL`, `LIMIT`, `LEVELS_SET`, `SHAPES`, `MAX_SECONDS` (defaults in the script header).
Validity knobs: `AHL_MIN_DATA` (5), `AHL_MIN_SUCCESSFUL` (20 — the *ceiling* of the per-level
request floor `max(5, min(20, 4*level))`, not a flat threshold), `AHL_ERR_TOL` (0.10),
`AHL_ERR_FATAL` (0.50), `AHL_DROP_TOL` (0.10), `AHL_MIN_MODEL_GB` (1.0), `AHL_ROOFLINE_SAFETY`
(3.0). `AHL_DISCARD_TOL` (0.30) is **retired** — kept for the audit's reporting, it is not the
`survivorship` rule. **`AHL_MIN_TOKENS` no longer exists** (contract v1.2 A1): setting it changes
nothing, and a test asserts that. Gate 2 has its own knob, `AHL_EVAL_MIN_SAMPLE_FRAC` (0.99).
Defaults live in `scripts/lib/validity.py`; the library reads the env at **call** time.

## Hardware notes

- `docs/hardware/<platform>.md` — the **platform-family** reference, shared across nodes of that
  platform (e.g. `gb10-dgx-spark.md`). GB10 is the DGX Spark reference design with many OEM
  rebrands — research across all vendor names.
- `results/<node_fp>/node_notes.md` — **this physical box's** narrative (firmware quirks, thermals).
- `node_profile.json` carries `gpu.mem_bw_gbs` — the memory bandwidth the roofline check is derived
  from. **Present and armed on this node since 20260819: 273** (GB10/LPDDR5X, 128 GB, 256-bit @
  8533 MT/s), hand-added with a `mem_bw_source` string recording that it is a spec figure and not a
  probe measurement, and corroborated in-lab at 255 GB/s = 93% of peak (llama.cpp FF711 decode
  roofline). Where the field is absent or `null` the `over_roofline` check is **skipped** — never
  guess a bandwidth number to make the check run, and if you add one by hand, record its provenance
  in `mem_bw_source` the same way.

## Variance

Benchmarks are noisy. For a keep/drop decision on a CONFIG, run **N=3** and take the **median**; don't act
on a single run (lesson from `homelab-tooling`). Don't change N mid-run. The median is taken over
**valid** rows only — `void` rows are not data and `suspect` rows are not citable, so N=3 means
three rows that passed the invariants, not three rows that exist.

## Conventions

- Dates absolute (`YYYYMMDD`). Tuning runs on branch `autoresearch/<tag>`.
- Inventory local docker images/containers before pulling (host already has the vLLM images).
- During an autonomous tuning run, follow program.md — don't pause to ask.

## Pending follow-ups

> **Triage against issue #1, 20260819–20260820.** The §1 work started as a validity layer for the
> **throughput** path only (`results.tsv`, Gate 3) and expanded twice. Nothing here is ticked off on
> a claim; every closed item names the evidence and every corrected item names what was wrong.
> **Closed in this wave:** `gpu.mem_bw_gbs`; Gate 2's missing acceptance predicate (contract A9);
> the historical-row adjudication (0 of 317 rows now disagree with their verdict); `keep` never
> being written (retired, contract v1.3); `promote.sh`'s version-derivation bug (now anchored to the
> pin); and **half** of the host-launcher `config_hash` blind spot (Gates 2 and 3 both use `hp3-`
> from the served process; the tier-3/4 eval scripts do not — see the new item).
> **Corrected but NOT closed:** accuracy-at-one-concurrency, the `LIMIT=100` noise item (its
> arithmetic is wrong for `mmlu` by 2.8× in SE), and the mmlu-drift item (its citation is wrong, its
> claim is right). Items the wave *created* are at the end of the list.
> The binding spec was amended eleven times for v1.1, ten more for v1.2 (two of those re-adjudicated
> after measuring), and once for v1.3: **contract v1.3 — its amendment blocks and its closing
> "v1.2 status" and "v1.3" sections — is what the code implements and what this file documents.**

- [x] **`promote.sh` version-derivation bug — CLOSED 20260820.** It used to set the `VLLM-<minor>`
  name by grepping the *first* `vX.Y.Z` in the runbook TEXT, which caught migration-comment lines
  (a baseline header saying `image v0.22.0 -> v0.23.0` yielded `VLLM-22-…` on a 0.23.0 config;
  workaround was `VLLM_TAG=23` by hand). **The name is a claim about which vLLM produced the
  numbers, so it is now derived from the PIN, never from prose:** `VLLM_TAG` if the operator sets
  it, else the `backends/vllm/image.lock` catalog entry for this exact digest, else a `vX.Y.Z` in
  the image REF's tag. A bare digest that is not in `image.lock` is **refused** (add it to the
  catalog, where a validated image belongs anyway, or pass `VLLM_TAG`), and the result must be
  numeric — `cut -d. -f2` on a catalog key like `0.23-fix` used to yield `VLLM-23-fix-…`, and
  `VLLM_TAG=abc` used to yield `VLLM-abc-…`. `promote.sh` prints `>> vLLM minor: N (from <source>)`.
  Living in the same script and unrelated: **`AHL_PROMOTE_OVERRIDE`** — the escape hatch for
  promoting on flagged supporting rows. It takes a **justification of ≥12 chars, not a flag**
  (`1`/`yes`/`force` are rejected), and the text is written permanently into the promoted `_final.sh`
  as a COMMENT, so every override is greppable across the whole runbook tree.
- [ ] **BUG: grammar-forced tool_choice 500s on the 35B production serve (found 20260712).**
  `tool_choice:"required"` AND named tool_choice both → HTTP 500: xgrammar `Failed to advance FSM
  ... grammar rejected tokens [248069, 271, 248058] ... Terminating request`. `tool_choice:"auto"`
  works perfectly (clean tool_calls). `response_format:json_object` returns 200 but output began
  with ```-fence → enforcement questionable. Suspects: reasoning `<think>` prefix not admitted by
  the tool-grammar, or MTP-accepted draft tokens bypassing FSM validation (all promoted configs use
  MTP). **ISOLATED 20260712: three-way interaction — grammar decoding × reasoning parser × MTP**
  (either alone fine; mtp-off OR think-off OR 0.25 image all pass; 0.25 = non-fatal recovery but
  json_object still non-strict with think+MTP). Full matrix in the 35B logbook. UPSTREAM (checked
  20260712): the whole cluster is KNOWN — #34650 (root: MTP breaks </think> detection in structured
  output, Feb), #46118 (fatal FSM reject, SAME token 248069), #48228 (doubled-brace response_format,
  filed 07-10 by another DGX-Spark user, Qwen3.6-27B; notes guided_json + think-off unaffected),
  #47025 (guidance-backend crash w/ spec decode), #44006→PR #44297 (MERGED 06-02: "trim grammar
  advance at the reasoning boundary" — why 0.25 recovers non-fatally), PR #44927 (OPEN since 06-08,
  0 reviews: should_advance() off-by-one — the remaining fix), RFC #48197 (07-10: full
  StructuredOutputManager × spec-decode refactor). Our 6-row isolation matrix POSTED to #48228
  (20260712): vllm-project/vllm#48228 issuecomment-4951567229. Watch #44927 + RFC #48197 for the
  fix; retest grammar smoke on 0.26; the outlines engine-crash leg is not filed upstream (could be
  its own issue if asked).
  ALSO: smoke.sh has NO grammar-path check (its JSON check is unforced sampling — hence the flakes);
  add Gate-1 check #5: tool_choice=required must return a tool_call, json_schema must comply.
- [x] ~~smoke.sh structured-JSON check needs a retry~~ **MISDIAGNOSIS, retracted 20260712**: the
  check runs `response_format:json_object` at **temp 0** — those "flakes" (`(`-prefix, doubled `{"`)
  were the xgrammar×reasoning×MTP grammar bug intermittently corrupting forced output, not sampling
  noise. Do NOT add a retry (it would mask a real defect the gate is correctly catching). The fix is
  the structured-outputs backend (see grammar-500 entry); smoke gained a de-facto grammar gate.
- [ ] **mmlu LIMIT=100 drifts ~1 pt across sessions on IDENTICAL config — CLAIM CONFIRMED, CITATION
  CORRECTED (20260820).** The original citation was wrong twice over: it said *"35B _final: 82.82 on
  **20260705** vs 81.72 on 20260712, same digest"*, but 82.82 is `20260704_v0.24.0_baseline.sh` on
  **20260704** and 81.72 is `VLLM-24-…_final.sh` — **two different configs**, not a repeat.
  **The phenomenon is real anyway, and now has proper evidence.** Grouping runbooks by their
  *comment-stripped* bytes (see the new `config_hash`-hashes-comments item) surfaces **three**
  same-effective-config `mmlu@5,700` replicate brackets:

  | model | values | Δ | note |
  |---|---|---|---|
  | `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 82.65, 81.72 | **0.93 pt** | 8 days apart, same image |
  | `RedHatAI/Qwen3.6-35B-A3B-NVFP4` | 78.19, 77.60 | **0.59 pt** | same day, same image |
  | `unsloth/Qwen3.6-35B-A3B-NVFP4-Fast` | 81.28, 81.32 | **0.04 pt** | same day, same `config_hash` |

  RMS repeat difference **≈0.64 pt** (per-run SD ≈0.45). The binomial SE of one `mmlu@100` run is
  0.509 pt, so a difference of two runs has a binomial-only SD of 0.72 pt — **0.64 is inside that**,
  so these brackets do not by themselves prove an extra session term; what they prove is that
  **0.6–0.9 pt is the wobble you must expect**, whatever its mechanism. A candidate mechanism now
  exists (20260820 lab note: prefix caching + fp8 KV makes the deployed serve non-reproducible run
  to run) but the journal does **not** corroborate it — see that note for the counter-example.
  Operational rule unchanged and now quantified: **re-measure the reference in the same session as
  the candidate**, and treat anything inside ~1 pt as not separable.
- [x] **vLLM 0.25.0 transition (20260712)** — pulled + digest-pinned (`image.lock` catalog; 0.24 still
  DEFAULT), capabilities diff clean (nothing removed; +hpc MoE, +dspark spec-method,
  +VLLM_MOE_SKIP_PADDING). 35B image-only baseline = NEUTRAL across all gates (c16/c1/acceptance/mmlu
  all ==) → no re-promote; 0.25 serve-validated. Note: **#46316 shipped in 0.25** — Qwen3-Next MTP no
  longer needs the patched image (only the pynvml patch, DGX-Spark-specific); rebuild per the
  image.lock 0.23.0-qwen3nextmtp-fix entry's instructions when next serving those models.
- [x] ~~**NEXT LAB RUN → vLLM 0.23.0.**~~ DONE (0.23 campaign 20260614, 0.24 transition 20260705,
  0.25 tested 20260712 — see above). Original notes: Released ~2026-06-12 (≈17h before 2026-06-13), a proper
  *release* (not a nightly) → the legitimate image bump. At transition: pull `vllm/vllm-openai`
  0.23.0, **pin by `sha256:` digest** in `image.lock`, `scripts/capabilities.sh` to verify the
  version + **diff** the flag/backend surface vs 0.22.0, then re-baseline native-FP4 on 0.23.0 and
  **re-verify the research-loop candidate queue against 0.23.0** (advice/kernels may differ). ~25GB
  pull — confirm first (see [[check-docker-before-pulling]], [[pin-vllm-releases-not-nightlies]]).
  Concrete 0.23.0 candidates to test (from release notes, VERIFY against actual notes + capabilities-diff):
  (1) `--linear-backend flashinfer_b12x` — FP4 GEMM for SM120/121 was excluded from auto on 0.22.0;
  0.23.0 syncs FlashInfer b12x → may beat native-FP4. (2) **re-test `--kv-cache-dtype fp8_e4m3`** —
  crashed at c16 on 0.22.0; 0.23.0 has per-tensor FP8 CUTLASS on SM12.1 + padding-bypass (+20%) +
  KV-deadlock fixes → may now work. (3) MoE-permute (+9–14%) + ARM64 image → relevant for the MoE
  models (Qwen3-Coder, Nemotron).
- [x] **Capability snapshot** — done: `backends/vllm/capabilities/0.22.0.txt` (+ caught
  cu130-nightly = 0.19.2-dev). The research loop now supersedes hand-picking from choice-lists.
- [x] **Add the `resistant` eval suite to `eval.sh`** — done: `resistant` defaults to **`mmlu_pro`**
  (tier 2, open). Now part of the **standard test suite** (`scripts/suite.sh`, baseline + finalize).
  (Tier 3 time-gated gold is `scripts/eval_live.sh` / LiveBench — still opt-in, not in the suite yet.)
- [ ] **Request HF access to `Idavidrein/gpqa`** (gated) to fold `gpqa_diamond_zeroshot` back into the
  `resistant` suite (`TASKS=mmlu_pro,gpqa_diamond_zeroshot`). Dropped from the default because the
  gating error aborts the whole lm-eval call. Graduate-level, very contamination-resistant — worth it.
- [ ] **Standard `mmlu` loglikelihood unreliable on some archs** — Gemma-4-31B scored mmlu=41 (vs
  gsm8k=73 healthy, smoke OK), pointing at a loglikelihood-path issue (Gemma BOS sensitivity /
  prefix-LM bidirectional attention / `final_logit_softcapping` on NVFP4). Decide per-model whether
  the quality gate uses mmlu (loglikelihood) or pivots to gsm8k + mmlu_pro (generative). Tie-in with
  the greedy-eval follow-up below.
- [ ] **Quality at c1/c32 — the RECORDING half and the TOKEN half are done; the SCORE half is still
  underpowered (found 20260818; premise corrected 20260819; measured live 20260820).**
  ~~`eval.sh:26` sets `CONC="${CONC:-16}"` and NOTHING in the repo has ever overridden it, so every
  accuracy row is a single point at c16 — and `accuracy.tsv` has no `conc` column.~~ **Both halves
  of that were wrong.** `accuracy.tsv` carries `conc` (contract A9), backfilled from each bundle's
  own `config.model_args.num_concurrent`, never stamped — and the bundles showed **two ds4 rows
  really ran at c4**, so `CONC` *was* overridden. Those two are `20260808-150310-eval` gsm8k=60.0
  and `20260808-153827-eval` gsm8k=76.0; the pair beside them (`20260809-210459`,
  `20260809-213330`, both 74.0) ran at c16, and all four share `config_hash 10b02344`. **So the
  60-vs-76 spread the host-launcher item calls ~3.7σ sits WITHIN a c4 pair: concurrency does not
  explain it.** Distribution over the 79 rows today: 75 at c16, 2 at c4, 1 at c1, 1 at c32.

  **What the live 20260820 run settled, and what it did not.** One serve, deployed config,
  `gsm8k LIMIT=100 THINK=off`, `CONC=1` then `CONC=32`:

  * **The tokens ARE batch-dependent — demonstrated, not hypothesised.** A 32-prompt greedy
    determinism probe with prefix caching disabled: **c1 vs c1 = 32/32 byte-identical** (clean
    control), **c1 vs c32 = 1/32** — 31 of 32 completions differ.
  * **The score did not move measurably.** 56.0 (c1) vs 58.0 (c32), n=100, SE≈4.9 per arm. That is
    no detectable difference, and **this design could not have detected one smaller than ~14
    points** — say both halves or the result is a lie by omission.
  * **Still open:** whether quality moves with concurrency *by score* needs either a task with real
    resolution (`mmlu@5,700`, not `gsm8k@100`) or a paired item-level test, which needs
    `--log_samples`. `research/review/POWER-analysis.md` §7.2's null experiment answers this in the
    same sitting as its own arms. Mechanisms remain: GEMM tile/split-k reduction order, piecewise
    CUDA-graph capture sizes and their fallback, the spec-decode rejection sampler running per
    batch, hybrid Mamba state under prefix-caching's forced `align` mode, preemption/recompute under
    KV pressure. Precedent: the tracked xgrammar × reasoning-parser × MTP bug is exactly a
    scheduling-dependent CORRECTNESS failure.
- [ ] **`LIMIT=100` accuracy noise — the ARITHMETIC WAS WRONG (corrected 20260820); the conclusion
  survives for `gsm8k` only.** ~~At n=100, p≈0.9, binomial SE is ~4.3 pts.~~ **`--limit` applies per
  LEAF SUBTASK.** `gsm8k@100` really is n=100 (SE 2.7 pt, MDE **14.08 pt** — 14× too coarse for a
  1% rule, not 4×). `mmlu@100` is **n=5,700** (57 leaves), SE **0.509 pt** — against lm-eval's own
  recorded median `acc_stderr` of **0.494** over the 24 kept `mmlu@100` bundles — MDE 2.06 pt.
  `mmlu_pro@100` is n=1,400, SE 1.22 pt.
  **The follow-up was wrong about `mmlu` by 7.6× in n, i.e. 2.8× in SE.** Two consequences:
  * the in-loop gate is *better* than believed on the task `eval.sh general` already computes and
    then ignores — the KEEP decision has been reading the `gsm8k` number off the same row;
  * the evidence this item cited as noise is **not** noise. "35B mmlu 77.6→82.82 across 7 runs"
    decomposes into three per-image clusters (0.23.0: 78.077±0.431 n=3 · 0.24.0: 82.235±0.582 n=4 ·
    0.25.0: 81.790 n=1) with a real **+4.158 pt** step at 0.23.0→0.24.0. Within-cluster spread
    matches what n=5,700 predicts. (An earlier draft called that step "8.5σ"; that figure is
    withdrawn as not reproducible — see POWER-analysis §2 for the three defensible statistics.)
  * **Still open, and it is a decision not a measurement:** the 1% clause is unachievable *unpaired*
    at any limit on any task in the suite (it needs 23,668 items/arm; `mmlu` has 14,042 in total).
    The defensible interim is a tolerance band equal to the **observed same-config spread**
    (~0.6 pt typical, ~0.9 pt seen — the three brackets in the mmlu-drift item above), cited on
    `mmlu@5,700`, with `gsm8k@100` demoted in writing to a breakage detector. Adopting anything
    with a *p-value* in it requires the null experiment first (new item below).
- [ ] **`config_hash` is blind to HOST-PROCESS launcher settings — HALF CLOSED 20260820; the open
  half is below.** The finding: ds4 gsm8k recorded 60.0 / 76.0 / 74.0 / 74.0 under an IDENTICAL
  `config_hash` (`10b02344`) — 60 vs 76 is ~3.7σ, not sampling noise, and it is **not
  concurrency** (the 60 and the 76 are both `conc=4`). The stub carries
  `MODEL`/`SERVED_NAME`/parser markers and nothing else, so every ds4 config hashed the same;
  `promote.sh` selects supporting rows BY `config_hash`, so a collision meant the validity gate
  could read rows from a different config.
  **Closed half:** `scripts/lib/hostcfg.sh` computes `hp3-<8 hex>` from the **served process** —
  argv (NUL-safe, repeated flags ordinal-tagged), the tuning env from `/proc/<pid>/environ`, the
  engine binary by content through `/proc/<pid>/exe`, and the scheme's own parameters; model files
  are identified by **content**, not basename (the two ds4 checkpoints share the basename
  `model.gguf` under different snapshot directories — the layout `huggingface-cli download`
  produces — and the old basename rule collapsed them onto one hash). **Both
  `bench_ds4.sh`/`bench_llamacpp.sh` (Gate 3) and `eval.sh` (Gate 2) write it**, from the same
  process, so a host config's quality row and its throughput rows finally join —
  and the four cited rows are rows in `accuracy.tsv`, so a bench-only fix would have left the
  tracked defect untouched. No historical row was rewritten: the `hp3-` prefix keeps old and new
  distinguishable by eye. `stub-<8 hex>` is written, labelled and warned about, when no known engine
  is serving the port. Selftest: `scripts/hostcfg_selftest.sh` (108 checks, fabricated `/proc`).
  **Open half:** the four historical rows still carry `10b02344` and cannot be separated
  retroactively — the processes are gone. Re-running them is the only way to attribute the 3.7σ
  spread, and *(see the new item)* five tier-3/4 eval scripts still hash the runbook.
- [ ] **~~Build a small PRIVATE held-out eval~~ (tier 4) — MECHANISM BUILT 20260820, NO ITEMS
  AUTHORED.** `scripts/eval_private.sh` + `scripts/eval_private_set.py` + the schema, the guard and
  a deliberately fake worked example (`evalsets/private-example/`) are committed; threat model and
  operating rules in [docs/private-eval.md](docs/private-eval.md); selftest
  `scripts/eval_private_selftest.sh` (**261 checks**). An adversarial verifier found **twelve**
  leakage paths through the first version — four HIGH — while its own 139-check selftest reported
  green; all twelve are closed with a regression test each, and two structural weaknesses are
  stated rather than pretended closed. **Authoring the real items is a human job and is the whole of
  the remaining work** — and read §8 of that doc first: never paste an item into an agent session,
  which includes whichever agent is reading this file.
- [x] **eval.sh pins greedy for eval** — done: `GREEDY=1` (default) sends
  `temperature=0,top_p=1.0,presence_penalty=0,frequency_penalty=0` per-request so the serving
  `--override-generation-config` can't bleed in (request params win over server gen-config defaults;
  confirmed forwarded — recorded in the bundle's results json). `GREEDY=0` / `GEN_KWARGS=…` to override.
- [x] **Generative-eval depression on REASONING models = thinking-mode (FIXED, thinking-off mode)** —
  root cause confirmed via sample logging: on the raw `/v1/completions` path the 35B emits `<think>`
  CoT that never closes within budget → answer truncated (gsm8k=40, `flexible-extract` 0.29 <
  `strict-match` 0.40 inversion). Fix wired in + verified end-to-end: `adapter.sh AHL_THINK_OFF=1`
  (server `--default-chat-template-kwargs '{"enable_thinking": false}'`) + `eval.sh THINK=off` (chat
  endpoint + `--apply_chat_template`) → **35B gsm8k 40→90**, no `<think>`, strict==flexible. suite.sh
  auto-applies it to reasoning models. (`enable_thinking` only works on `/v1/chat/completions`, not the
  raw completions path — lm-eval can't pass it via CLI gen_kwargs as a nested dict, so it's server-side.)
- [ ] **Passwordless sudo (narrow)** — decide whether to allow `sysctl -w vm.drop_caches=3`
  (unified-memory cache hygiene before a run) and `nvidia-smi --gpu-reset` (recover a wedged GPU
  if `adapter down` ever isn't enough). Currently `drop_caches` is **skipped** (sudo unavailable
  non-interactively) and recorded as such in the protocol. User's call: add a sudoers rule for
  just these two, or keep manual.

*Created by the issue-#1 validity work (20260819-20260820):*

- [x] **~~Adjudicate the 315 historical rows~~ — CLOSED 20260820. 0 of 317 rows disagree with their
  verdict.** Contract §7 backfilled `req_counts`/`validity`/`knobs` from the retained
  `level_c*.json` bundles but deliberately did **not** rewrite historical `status` values in bulk —
  several are cited in logbooks and in promotion decisions, so flipping one to `void` silently
  invalidates a published claim. The queue was walked row by row instead: six fatal rows to `void`
  and two promoted runbook headers corrected on 20260819, then the last thirteen on 20260820 (the
  audit: `research/review/AUDIT-measurement-validity.md`). The corpus now reads
  **284 `measured` / 12 `crash` / 8 `suspect` / 7 `void` / 6 `discard`**, every `discard` carries an
  `adjudicated@YYYYMMDD who: reason` stamp, and
  `python3 scripts/lib/validity.py status --tsv results/*/*/*/results.tsv` exits 0.
  **What is permanently unclosable: 6 rows whose bundles are gone.** That is the hard ceiling on how
  much of this record can ever be verified; treat them as uncitable rather than assumed good.
- [x] ~~**`gpu.mem_bw_gbs` is absent from the existing node profile**~~ **DONE 20260819.** Added to
  `gb10-1988a9714b4e` as `273` with a `mem_bw_source` string recording that it is the GB10 spec
  figure, hand-added rather than probed, and independently corroborated in-lab at 255 GB/s (93% of
  peak). The node fingerprint was proven unchanged by the edit. **The roofline is armed today** —
  `over_roofline@c16` fires on the 449,358 row. No re-probe needed; `probe.sh` gained a
  `mem_bw_for_gpu()` platform table so new nodes get it automatically.
- [x] **Gate 2 had no validity layer at all** — **CLOSED 20260819 (contract A9).** The original
  finding: of the three defects that motivated the contract, the mmlu-on-spec-decode NaN run is a
  *Gate-2* failure caught by none of the throughput verdicts; it was fixed by a specific
  branch-order fix (20260817), not by a general invariant. Verification then found Gate 2 had **no
  acceptance predicate whatsoever** — `suite.sh` judged it on `eval.sh`'s exit code alone, and
  `eval.sh` exited 0 whatever came back, so `mmlu: acc = NaN`, a score over **37 of 14,042**
  requested samples, and a missing results json each wrote a row and reported **PASS**.
  Now: `scripts/eval_validity.py` scores every bundle (`no_score` / `nonfinite` / `short_sample`
  fatal, `zero_score` / `no_samples` suspect), `accuracy.tsv` carries `conc`/`samples`/`validity`/
  `status`, and a non-citable quality result exits 4 and fails the suite. The denominator the
  finding asked for is the `samples` column: `effective/requested` per task, from the bundle's own
  `n-samples`. Its residual gaps are now a separate open item (placeholder-filled samples, below).
- [x] **~~`keep` has never been written to a `results.tsv` row~~ — CLOSED 20260820: `keep` is
  RETIRED** (contract v1.3). 0 of 317 rows ever carried it, and the reason is structural, not an
  oversight: a keep verdict is per-CONFIG on a median of N, while `status` is per-ROW and is written
  before that comparison exists. The word is now *refused*, not merely undocumented —
  `check_status()` raises on it and both runners reject `STATUS=keep` on the usage rung. `discard`
  stays, redefined as a signed §7 orchestrator adjudication. Full reasoning: "Status vocabulary"
  above. The question the old item actually wanted — *"which rows support this promotion?"* — is
  answered by `citability.py gate` plus the `exp=` tag in `notes`, not by a status word.

*Created by the 20260820 verification wave (statistical power, host identity, interrupt recovery):*

- [ ] **`config_hash` hashes runbook COMMENTS — the vLLM-side twin of the host-launcher blind
  spot.** `sha256sum <runbook>` covers the whole file, so `promote.sh` copying a winner and
  prepending a `# Result: ...` header **mints a new identity for a byte-identical serving config**.
  Measured across the tree: **12 pairs of runbooks (24 files) are identical once full-line comments
  and blank lines are stripped**, i.e. 24 `config_hash` identities for 12 configs — every promoted
  `_final.sh` beside the `baseline.sh` or `_tuned.sh` it was promoted from. This is not cosmetic:
  it **hid the entire cross-session accuracy replicate evidence**. The mmlu-drift item above went
  months without a same-config repeat bracket because the only ones that exist are split across a
  comment-only difference (82.65 vs 81.72 is `20260704_mtp-n2_tuned.sh` vs `VLLM-24-..._final.sh` —
  the same config). Fix: hash the runbook's *effective* content (strip full-line comments), or hash
  the resolved `MODEL`/`MODEL_REVISION`/`VLLM_IMAGE`/`VLLM_FLAGS`/`VLLM_ENV` set. Note the cost:
  every historical `config_hash` moves, so it needs the same prefix treatment `hp3-` got.
- [ ] **Five tier-3/4 eval scripts still hash the RUNBOOK for host backends.** `eval.sh` (Gate 2)
  and the three benchers use `hp3-` from the served process; `eval_live.sh`, `eval_livebench.sh`,
  `eval_livecodebench.sh`, `eval_bfcl.sh` and `eval_private.sh` all still do
  `CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"`. For a `.smoke-runbook.sh` stub that is the
  colliding identity the whole `hp3` work exists to remove, so a LiveBench or private-set row for a
  ds4 config cannot be joined to its Gate-2/Gate-3 rows. Small fix — the same `case` block `eval.sh`
  already carries — but it must be ONE shared helper, not five copies (the five hand-rolled
  `classify` bodies are the standing warning).
- [ ] **Gate 2 cannot see PLACEHOLDER-FILLED items, and one flag closes that and the psi gap at
  once.** When a completion comes back with null content, lm-eval substitutes
  `LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER` and **counts the item as answered**: `n-samples` says
  `100/100`, the score is finite and non-zero, and `eval_validity.py` returns `ok`. Measured live
  20260820: `RedHatAI/Qwen3-8B-NVFP4` under think-off returned null content on **17-19%** of gsm8k
  items and scored 56 against a think-on 90, with `validity=ok`. Detecting it needs the per-item
  outputs — i.e. **`--log_samples`** on `eval.sh`, which writes `samples_<task>_<ts>.jsonl` per leaf
  into the already-gitignored bundle at ~20 MB per `mmlu@100` run and **zero GPU seconds**.
  `research/review/POWER-analysis.md` wants the same flag independently, to measure the item-level
  discordance psi that every paired figure in it currently projects. **One flag, two open items.**
  Wiring note: `mmlu@100` writes **57 files**, one per leaf — pass them all to
  `power.py mcnemar --samples-a ... --samples-b ...`, never concatenated (`doc_id` restarts per leaf).
- [ ] **The NULL EXPERIMENT must run before any p-value enters the contract** (~2.5 GPU hours,
  once). Everything paired in the power analysis is a projection over an unmeasured psi, and the
  three brackets we have imply psi = 0.0014, 0.312 and 0.774 — the entire admissible range, i.e. no
  constraint at all. Design (POWER-analysis §7.2): one config, `mmlu@LIMIT=100` with
  `--log_samples`, four arms — **A** two runs back to back in one serve session, **B** two runs in
  *different* sessions, **C** A and B on a config with `--enable-prefix-caching` +
  `--kv-cache-dtype fp8_e4m3`, **D** A and B on a config with neither. Output: the observed
  `(b, c)` per arm, which is the null distribution. **A p-value may enter the contract only if arms
  A and B both return p >= 0.05 at the intended alpha** — and the naive McNemar gate that was
  drafted and then **retracted** fails a config against itself at any psi below 0.1237, so this is
  not a formality. Run arms A/B at `CONC=1` and `CONC=32` and it closes the quality-at-c1/c32 item
  in the same sitting.
- [ ] **RULING NEEDED: discard bench #1 from every variance estimate (throughput).** The first bench
  of an experiment runs slow at c16 — pooled **-1.22%, t = -3.05** over 63 complete 3-bench
  experiments, 40% of the KEEP threshold. It cancels between two medians but **not in the
  variance**, which is what every MDE is computed from. Dropping bench #1 takes the global c16 CV
  **2.25% -> 1.55%**, the MDE 6.09% -> 4.18%, and the false-keep rate of the `>3%` rule
  **8.1% -> 2.1%** — at **zero GPU cost**, and cheaper than raising N from 3 to 4 (which reaches
  only 4.6% for +34 min per campaign). It also flips the corpus audit from "1 of 55 historical calls
  unsupported" to "0 of 55". **Honest caveats:** it is not a global warm-up law — two campaigns
  (`Qwen3-8B-NVFP4` -5.15%, `VibeThinker-3B` -5.24%, both |t| > 30) carry the whole pooled effect
  while five of the nine models with k >= 3 go the other way (two-sided sign test p = 1.0), and the
  mechanism is unknown; it is not prefix caching (those 12 experiments are the *tightest* group at
  -0.09%) and it is over after bench 1 (n2 vs n3 = +0.05%, t = 0.17). **Not adopted. Someone has to
  rule**: change how `run_experiment.sh` summarises (median benches 2..N), or bench 4 and median the
  last 3, or leave it and document the bias.
- [ ] **Variance is a per-model property and the KEEP threshold is global.** Pooled c16 CV spans
  **0.58%** (35B, 11 brackets) to **3.37%** (Nemotron-120B, 8) — a 6x spread in CV, 6x in MDE and
  500x in false-keep rate, all judged against one 3% line. Worse, the variance component that
  *governs* a comparison is usually not the one being used: of 55 historical candidate-vs-baseline
  deltas, **34 are same-session**, 15 are cross-day (governed by a cross-day CV resting on **three**
  brackets) and **6 are cross-image — for which this repo has no error term at all**, including a
  promoted artifact. Cheap first step: print the model's own `mde=...% false_keep=...%` on the
  `MEDIAN` line (`power.py throughput --model <exact id> --drop-first`, refusing to answer under 3
  brackets) and label each recorded delta with the component that governs it. Gating on a per-model
  MDE is premature while the estimates rest on 3-11 brackets each.

---

## Lab notes & observations (living — keep updated)

**MEASUREMENT VALIDITY — the failure mode of this codebase is a plausible number, not a crash (20260819)**
- Three separate defects in ONE session each wrote `status=measured` and **none of them errored**:
  (1) the coder shape starved at `MAX_SECONDS=180` and reported c32 = **256.19 tok/s computed from
  2 completed requests**, with a non-monotonic curve (c8 70.88 > c16 68.88); (2) MTP n=4 killed the
  server mid-stage and a handful of instant failures against the dead endpoint became
  **`tps_c16` = 449,358** and **1,992.87**; (3) `suite.sh` ran loglikelihood `mmlu` on a spec-decode
  config — **56,168 requests returning `400 NaN`** for 1h15m with the progress bar advancing
  normally, and it would have reported a score over whatever subset happened not to NaN.
- **Two of the three were caught only because a human eyeballed the shape of the numbers.** The
  third was caught by an odd request count on a progress bar. That is not a control; that is luck,
  and it does not scale to 317 rows across 15 campaigns.
- The common structure: every failing component **kept running and kept producing output**.
  GuideLLM averages `successful` only and silently drops in-flight requests; lm-eval retries a 400
  and continues; a dead endpoint returns fast, and fast looks like throughput. Each layer degraded
  gracefully into a number, and a number is exactly what the journal accepts.
- The fix is not more care. It is **invariants that run on every row**: a per-level request floor
  (`max(5, min(20, 4*level))`), majority-discard survivorship (`incomplete > ok`), a floor as well
  as a ceiling on throughput (`no_output`: successful requests that produced no tokens), an error
  band that goes fatal above 50%, a physical roofline (449,358 tok/s **at c16** on a 273 GB/s box implies
  16×273/449,358 = 0.0097 GB of weight traffic per token, i.e. a **9.7 MB model** — refutable from
  first principles without knowing which model was served), adjacent monotonicity, error rate. Plus
  the counts written INTO the committed row (`req_counts`), because the bundle that proves a number
  is gitignored and the number is not.
- **Calibrating the invariants was itself measurement work, and the first TWO calibrations were
  wrong — for `low_sample` and for `survivorship` alike.** The flat 20-request floor shipped in
  v1.0 flagged 55% of the corpus. Its v1.1 replacement, a 2048-token budget, was refuted by two
  verifiers independently: it fired alone on 3 of 693 bundles (all three the most reproducible
  bracket on this node, CV 0.59–0.70%), correlated with measured reproducibility at **r = -0.006**,
  and would have APPROVED 10 of the 15 genuinely starved levels because a coder completion carries
  ~1000 tokens. `survivorship` went wrong twice in the other direction: v1.1's form could not fire
  below a 50% discard rate while citing 32.4% regimes, and v1.2's first attempt was arithmetically
  unsatisfiable and fired zero times on 690 levels. **Run a new invariant over the existing corpus
  before you ship it, and run it BOTH ways** — how often it fires on known-good rows, and whether
  it fires at all on the rows it was written for. A rule you cannot afford to obey teaches people to
  ignore the column; a rule that cannot fire teaches them it is covered. Over the 317-row corpus:
  **284 ok (89.6%) / 9 suspect-floor / 23 void-floor / 1 na**, all three motivating defects caught.
- **Generalize it:** any metric derived from "the mean of the requests that finished" is a lie
  whenever the interesting failure is *not finishing*. Before trusting a mean, ask what got
  excluded from it. The corollary for tooling: when a component fails, prefer that it stop rather
  than continue at reduced fidelity, and when it can't stop, make the fidelity a recorded column.
- **The layer was validated on real hardware 20260820, and it caught a live inflated number.** First
  GPU run of the whole thing — everything before it was fixtures and retained bundles. Healthy run
  on the promoted Qwen3-8B final: c1 = 41.26 (against a 41.87–42 reference spanning two months and
  three vLLM versions), c16 = 535.62, `validity=ok`, exit 0. Same config minutes later with a 20 s
  stage: **3 requests drained and 63.34 tok/s reported, 54% above the truth** — written `void`,
  exit 4, counts printed at the moment it happened. Before this layer that row would have been
  `status=measured` and indistinguishable from a measurement.
- Rules now: [docs/validity-contract.md](docs/validity-contract.md) **v1.3** (binding — its
  amendment blocks and the closing "v1.2 status" / "v1.3" sections win over anything earlier in the
  file), the Results-model section above (schema + vocabulary),
  [docs/validation.md](docs/validation.md) (Gate 3 by hand), `scripts/eval_validity.py` (the same
  idea on Gate 2), program.md → "Invalid runs" (what an operator does about it),
  `research/review/AUDIT-measurement-validity.md` (what the invariants say about the published
  record), `research/review/POWER-analysis.md` (what the two gates can and cannot RESOLVE),
  `tests/run.sh` with `AHL_TEST_STRICT=1` (the acceptance gate, **279 tests**) plus
  `tests/mutate.sh` (**38 mutations, 0 survivors** — the gate on the gate).

**A CORRECT CONDITION IN AN UNREACHABLE BRANCH — FIVE times in this repo, twice with a comment
saying otherwise (20260817-20260820)**
- Five separate guards in this codebase were *right* and did *nothing*. They are not the same bug
  and they were written by different hands, months apart, which is what makes this the repo's named
  failure mode rather than five fixes.
  1. **`suite.sh`'s reasoning × spec-decode `if/elif`** (found 20260817). The spec-decode branch
     correctly refused to run loglikelihood `mmlu`. It was second, and reasoning was first, so every
     runbook that is BOTH — i.e. every promoted reasoning model with MTP — took the reasoning branch
     and ran `mmlu` anyway. Cost: a **56,168-request, 75-minute** eval emitting `400 ... nan` per
     request with the progress bar advancing normally, which would have reported a score over
     whatever subset happened to survive.
  2. **`bench.sh` reading verdict globals nothing ever set.** The enforcement code was there and
     read variables the library call never assigned; on a library failure it defaulted
     `STATUS_FLOOR=ok` and exited 0. A `uv` hiccup therefore produced a fully citable row. The
     roofline was worse than dead: `bench.sh` never passed `--node-profile`, so §4 was dead code on
     the **primary** bencher while the two host-process benchers ran it.
  3. **Contract v1.2 A2's own `incomplete > level`.** Written to subtract the steady-state in-flight
     set before judging discard. GuideLLM *bounds* in-flight by the concurrency level (88.8% of
     levels sit at exactly `level-1`, max ratio 1.000), so the condition is **unsatisfiable**: it
     fired **zero times on 690 levels** and missed all 53 level-instances it was written to catch.
     A spec can ship an unreachable branch exactly as easily as an implementation can.
  4. **`--node-profile` was never passed, so the roofline was dead on the PRIMARY bencher.** Listed
     above as part of (2) and worth counting separately, because the two host-process benchers
     *did* pass it: the check was demonstrably alive somewhere, which is exactly what makes a dead
     copy invisible. "The rule works" and "the rule works on the path that matters" are two claims.
  5. **A `trap` that could not fire until `LEVEL_TIMEOUT`** (found 20260820). The interrupt handler
     was installed and correct, but **bash defers a trap until the foreground command returns** —
     so a Ctrl-C during a GuideLLM level did nothing until that level's `timeout` expired, minutes
     later, by which time the operator had usually escalated to `SIGKILL` and the row was lost
     anyway. The condition was right, the handler was right, and the window in which it could run
     did not exist. Fixed by running children in their own session and reaping them; the regression
     tests **send the signal** while the process is provably inside a level (a marker file, not a
     timing guess), because no assertion about the trap's condition could have caught this.
- **Two of the five carried a comment asserting they were live.** `assess_bundle`'s comment stated
  the inverse of what its code did; the amendment text described a rule that could not fire. The
  comment is not evidence. Neither is a code review of the condition, and neither is a test that
  asserts the condition is correct — all three of those were satisfied here.
- **The generalization: "this condition is correct" and "this condition is reached" are different
  claims, and only the second one needs an execution trace.** Reading gives you the first. A test
  that greps for a token gives you neither: `_needs("promote.sh", "void", "suspect")` passed on a
  comment saying void and suspect were unhandled. What gives you the second is running the real
  script against stubbed children and asserting on *which branch executed* — the emitted row, the
  exit code, the call log.
- What we now run because of this: **`scripts/citability_selftest.sh`** (**102 checks** — real
  `promote.sh`/`suite.sh`/`validate.sh`/both runners in a throwaway repo with scripted-exit stubs),
  the Gate-2 execution traces in **`scripts/eval_validity_selftest.sh`** (**96 checks**, all four
  runbook variants including reasoning **AND** spec-decode), `tests/test_interrupt_recovery.py`
  (**59 tests** that actually signal the real `bench.sh` mid-level), and **`tests/mutate.sh`** —
  which is the reachability question asked backwards: **38 mutations, 0 survivors**, where a
  mutation that does not turn the suite red proves the rule it broke was never exercised. Mutation
  testing of the v1.1 suite found **16 survivors at 121/121 green**, including every enforcement path.
- Corollary for anything with an `elif`: **test the COMBINATION first.** Mutually exclusive branches
  are a claim about the inputs, and in this repo the input that is both things at once is the
  normal case, not the corner.
- **THE MIRROR IMAGE, learned in the same wave: a test can assert a bug as desired behaviour, and a
  green mutation can be an unfaithful mutation.** Two new shapes, both of which look like coverage:
  * **A selftest case asserted the defect.** One case pinned that an *uncatalogued* image should
    take its version from a trailing comment in the runbook — which was precisely the
    `promote.sh` version-derivation bug. The suite was green, the mutation harness was happy, and
    the assertion was wrong. A test inherits its author's model of correct behaviour; nothing in a
    test framework can tell you that model was the bug.
  * **A reported "survivor" is a hypothesis, not a finding.** In this wave a mutation survived not
    because the rule was untested but because the *harness* was wrong: the case set the env
    override after the library had been sourced, and this library reads its env at **call** time —
    the same source-time/call-time trap the ten-worktree merge recorded below. It died as soon as
    the variable was set first. Before writing a test for a survivor, confirm the mutant genuinely
    breaks the rule it names and that the case genuinely exercises it; otherwise you are adding
    coverage for a bug you did not introduce.
  * **And the harness itself can fail into a clean-looking result.** `tests/mutate.sh` copied the
    5.1 GB `.venv` for every mutation, so a 38-mutation run was hours of I/O; one run died mid-table
    on `file changed as we read it` while another agent wrote into the tree — a silent `set -e`
    abort that printed a **short table with no failures**, which reads exactly like a clean sheet.
    The copy is now 4.8 MB and a failed copy is a loud error. Same family as everything above:
    **the absence of a red line is not evidence, unless you know the run reached the end.**
- **The generalization worth carrying: correctness, reachability and TEST FAITHFULNESS are three
  separate claims, and each needs its own kind of evidence.** Reading gives you correctness. An
  execution trace gives you reachability. Faithfulness — "this test asserts the behaviour we
  actually want, and this mutation really does break the rule it names" — is given by neither, and
  it is the one that survives a green suite. When all three are unchecked you get a codebase that
  believes it is protected.

**THE DEPLOYED SERVE IS NOT RUN-TO-RUN REPRODUCIBLE — prefix caching is the cache STATE (20260820)**
- Measured on this box, `RedHatAI/Qwen3-8B-NVFP4` promoted final, config unchanged. Repeat an
  identical 32-prompt greedy pass through `/v1/completions` and compare the completions byte for
  byte:

  ```
  deployed (enable_prefix_caching=True, kv_cache_dtype=fp8_e4m3):   7/32 byte-identical
  same config with prefix caching OFF:                             32/32 byte-identical
  ```

- **It is not general nondeterminism.** A *single* prompt repeated 5× is deterministic either way.
  It is cache STATE: where a prefix-cache hit lands varies with eviction pressure, and an fp8 KV hit
  reuses quantised KV instead of recomputing it, so two runs of the same batch take different
  numerical paths through the same weights.
- **Operational consequence: anything that needs bit-reproducibility must serve
  `--no-enable-prefix-caching`.** That includes a differential debug session, a paired item-level
  eval, and any claim of the form "these two runs produced the same output".
- **STATE THE LIMIT HONESTLY — this is ONE controlled A/B on ONE config, and the journal does NOT
  corroborate a feature-conditional accuracy tolerance.** It is tempting to read it as the mechanism
  behind the mmlu-drift item, and all three `mmlu@5,700` replicate brackets do sit on configs
  carrying prefix caching + fp8 KV + MTP together. But an auditor found the direct counter-example
  in our own record: the gemma `20260614_kvfp8_tuned.sh` bracket has **no prefix caching** and moved
  **3 of 100 items (3.0% net flip)** — higher than the prefix-cache 35B's 0.93%. n=3 on one side,
  n=2 on the other, the three features confounded with each other and with MTP, and the determinism
  probe measures the **serving** path, not lm-eval's scoring path. **Corroboration, not proof.** Do
  not generalise it into a rule until POWER-analysis §7.2's arms C and D have run.

**CONCURRENCY CHANGES THE TOKENS, NOT MEASURABLY THE SCORE (20260820)**
- Same box, same serve, `gsm8k LIMIT=100 THINK=off`, greedy, one serve session, `CONC=1` then
  `CONC=32`. Both halves matter and neither is the headline on its own.
- **The tokens: batch-dependent, demonstrated.** 32-prompt determinism probe with prefix caching
  disabled so the cache effect above cannot confound it — **c1 vs c1 = 32/32 byte-identical**
  (the control), **c1 vs c32 = 1/32**. Thirty-one of thirty-two completions differ. The mechanism
  the open follow-up hypothesised is real: batch size changes what the model emits.
- **The score: no detectable difference, and the design could not have found one.** 56.0 at c1 vs
  58.0 at c32, n=100, SE ≈ 4.9 per arm. `gsm8k@100` resolves ~14 points at 80% power, so "no
  difference" here means "nothing bigger than 14 points", which is not the same sentence.
- **Say both halves or it is a lie by omission.** "Concurrency doesn't affect quality" is not
  supported by this; "concurrency changes what the model emits, and we have no evidence it changes
  how often the model is right" is. Resolving it properly needs `mmlu@5,700` rather than
  `gsm8k@100`, or a paired item-level test — which needs `--log_samples` (open follow-up).

**THINK=off CAN COLLAPSE A MODEL, AND GATE 2 PASSES IT `validity=ok` (20260820)**
- `RedHatAI/Qwen3-8B-NVFP4`, same day, same config: **think-on gsm8k = 90–92** (87.64 at full limit,
  20260613/14) versus **think-off gsm8k = 56–58**. A 34-point collapse, with **17–19% of items
  returning null content**.
- **Gate 2 reports it clean.** lm-eval substitutes `LMEVAL_MODEL_NONE_ANSWER_PLACEHOLDER` for a null
  completion and **counts the item as answered**, so `samples=100/100`, the score is finite and
  non-zero, and `eval_validity.py` returns `validity=ok`. The predicate is not wrong — it cannot see
  per-item content without `--log_samples` — but the row looks like a measurement.
- **This is live, not hypothetical:** `suite.sh` auto-applies think-off to **every** runbook carrying
  `--reasoning-parser`, so for this model the Gate-2 result silently becomes 56 instead of 90.
- It is the NemotronH failure (`enable_thinking=false` rendering a pre-closed `<think></think>`)
  appearing **partially rather than totally, which is worse**: a total failure scores 0.0 and trips
  `zero_score`, and a partial one scores plausibly and trips nothing.
- **The "Thinking-OFF generative eval" note under "Standard test suite → Gate 2" must not be read
  as "the fix always helps".** The 35B went 40→90 with thinking off; this model goes 90→56.
  **The direction is model-dependent.** Probe a new reasoning arch's think-off serve — is `content`
  non-empty? — before trusting any generative score from it.

**PARALLEL AGENTS — disjoint file ownership prevents MERGE conflicts and does nothing about INTERFACE drift (20260819)**
- Ten agents built the validity layer in ten worktrees with strictly disjoint file ownership. The
  merge produced **zero file conflicts** and **six API mismatches at the seams**: one agent had the
  bash shim's field order *and* field count wrong; two coded against library function names that
  never shipped; one wrote a harness that applied env overrides only across the import, while the
  library reads its env at **call** time, so every override silently did nothing.
- **git conflict-free is not integration-tested.** A conflict is a *collision* on the same bytes;
  the expensive failures here were *agreements that never happened* — two files that both compile,
  both pass their own author's tests, and disagree about a name, an order, or when a value is read.
  Nothing in the VCS can see that, and none of the six would have been caught by review of either
  file alone.
- What actually caught them: a **hermetic acceptance suite written against the contract rather than
  against any implementation** (`tests/run.sh`, **279 tests**, stdlib only, no GPU/network/container),
  run with `AHL_TEST_STRICT=1` so a SKIP fails — because pre-merge those tests skip with a message
  naming exactly what is missing, and post-merge a skip means "this contract rule was not checked",
  which is indistinguishable from a hole.
- Rules for the next fan-out: (1) fix the interface in a written contract *before* the fan-out, and
  version it — v1.0 → v1.1 was eleven evidence-driven amendments, v1.1 → v1.2 another ten from four
  independent verifiers (two of those ten re-adjudicated after measuring), and v1.2 → v1.3 the
  status vocabulary; having a version number is what let ten branches be told, unambiguously, what
  they now had to match; (2) exactly one
  agent owns each shared API and everyone else consumes it, never re-implements it; (3) budget an
  explicit integration pass — the merge is where parallel work costs its time, not the writing;
  (4) write the seam tests against the spec, not against the code that exists.
- Corollary for the docs: the same drift is what put a 16-column schema in this file while four
  scripts agreed on 20. Interfaces drift toward whatever is *executed*; anything not executed —
  documentation especially — has to be pulled along deliberately.

**Hardware — GB10 (node #1) — UNIFIED MEMORY CAVEATS (expect odd results)**
- sm_121 (Blackwell), aarch64, ~121.6 GiB **unified** LPDDR5X (~273 GB/s); driver 580.159.03, CUDA 13.0.
- `nvidia-smi` reports GPU `memory.total/used` = `[N/A]`. `peak_gb` therefore falls back to
  **system used memory** (MemTotal−MemAvailable) as a proxy — approximate, confounded by the OS.
- `--gpu-memory-utilization` is a share of the **whole shared pool**, contended with OS/CPU/
  runtime. High values can starve the OS and destabilize the *box*, not just the GPU. Baseline
  uses **0.50** on unified nodes; push up only if stable.
- Decode is **memory-bandwidth-bound** (LPDDR5X ≪ HBM): absolute tok/s runs low vs discrete GPUs,
  and the concurrency curve can **plateau or even regress** at high concurrency as bandwidth
  saturates — that's expected here, not a bug. Don't compare GB10 tok/s to HBM GPUs naively.
- Results drift with **background system load** (shared pool). Quiesce the box before a run; N=3
  median; record anomalies in `results/<node_fp>/node_notes.md`.

**vLLM / images**
- vLLM ships **sm_120** kernels, forward-compatible to the GB10's **sm_121**.
- Pinned images present locally: `vllm/vllm-openai` `v0.22.0` (default), `cu130-nightly`,
  `v0.17.1-cu130`. Don't re-pull (tens of GB each).
- `vllm/vllm-openai` ENTRYPOINT is already `vllm serve` → pass MODEL positionally. NGC
  `nvcr.io/nvidia/vllm` needs explicit `vllm serve` (`VLLM_ENTRYPOINT_SERVE=false`).
- NVFP4 = compressed-tensors (auto-detected; usually no explicit `--quantization`). Dense models
  (e.g. Qwen3-8B) don't use `--moe-backend`; MoE NVFP4 models do (`flashinfer_cutlass`/`marlin`).

**GuideLLM** (pinned **0.6.0**)
- Use `--profile concurrent --rate 1,4,8,16,32`, **not** `sweep` (sweep ramps in-flight toward
  512, never drains for non-trivial outputs → every request cancelled → tok/s = 0).
- Keep `--max-seconds ~180` so each stage completes enough requests for stable stats.
- 5 `benchmarks[]` map 1:1 to the rate list; tok/s = `output_tokens_per_second.successful.mean`.
- **0.6.0 gotcha:** synthetic `--data "prompt_tokens=…,output_tokens=…"` still parses (key=val,
  needs >1 `=`), but you MUST pass **`--processor <full HF repo>`** — synthetic-text generation
  needs a real tokenizer and the short `--served-model-name` is not resolvable. bench.sh passes
  `--model "$SERVED_NAME" --processor "$MODEL"`.
- **`MAX_SECONDS=180` is NOT universal — it assumes a fast model. Scale it to the model.**
  `output_tokens_per_second.successful.mean` averages only requests that COMPLETED; everything still
  in flight when the stage ends is `incomplete` and silently excluded. On a slow model the coder
  shape (4096/1024) needs ~50 s per request, so a 180 s stage drains 2–5 requests per level and the
  "result" is an average over a handful of lucky completions — which goes **non-monotonic** yet still
  looks like a real measurement (FF711 20260809: coder c1 27.57 → **c4 121.23** → c8 47.72 → c16
  56.42, all void; the chat shape at 39–42 successful was fine). **Before trusting any GuideLLM mean,
  check the successful/incomplete counts in the level json**:
  `jq '.benchmarks[0].metrics.request_concurrency | {ok:.successful.count, inc:.incomplete.count}'`.
  Slow dense models need `MAX_SECONDS>=600` for coder.
  **This check is now automated** — the counts land in the row's `req_counts` column and the
  judgement in `validity` (Results model above). Run the `jq` by hand only for a historical row
  whose bundle predates the columns.
  **CORRECTION 20260819 — the old "≥20 successful per level" rule of thumb is RETIRED, and this
  note's explanation of the non-monotonic coder curve was the wrong mechanism.** (a) Request count
  does not predict reproducibility: median CV of reported tok/s across 77 replicate brackets is
  **0.39% at n<10** and **1.42% at 10≤n<20** vs **0.56% at 20≤n<50**. Twenty requests was never the
  quantity that mattered. (b) The inverted coder curve is **survivorship bias**, not a small-sample
  artifact: `successful.mean` drops the `incomplete` requests, and the dropped ones are the SLOW
  ones, so the reported mean is the mean of the faster half — a directional bias that grows with
  concurrency. Measured discard rates on our own record: chat c1 **0.1%**, chat c32 **10.3%**,
  coder c16 **32.4%**, coder c32 **46.2%**. At coder c32 nearly half the work is thrown away before
  the average is taken. Throughput is not falling at high concurrency; the estimator stops keeping
  up.
  **SUPERSEDED 20260820 (contract v1.2 A1), the part about tokens.** This note briefly said tokens
  generated is what predicts reproducibility, "hence the `AHL_MIN_TOKENS=2048` budget". **That
  budget no longer exists and the inference was wrong**: it correlates with measured reproducibility
  at r = -0.006, fired alone on 3 of 693 bundles (all three false positives on this node's *most*
  reproducible bracket), and because a coder completion carries ~1000 tokens it would have approved
  10 of the 15 genuinely starved levels. Neither requests nor tokens predicts reproducibility on
  this corpus; `low_sample` is now a bare structural floor, `max(5, min(20, 4*level))`, which at c1
  collapses onto `AHL_MIN_DATA` and therefore cannot fire there at all.
  **AND the 30–48% coder discard above is NOT flagged by any verdict.** The shipped `survivorship`
  rule is majority-discard (`incomplete > ok`) because a 30% threshold flags 19 of 23 coder rows —
  which is a statement about the measurement METHOD, not a per-row defect. So the bias is real,
  systematic, and invisible to `validity`: **when you cite a coder number at c8 and above, check
  `req_counts` yourself.** The honest reading of a high-concurrency coder figure is "the throughput
  of the requests that finished", and the fix is `MAX_SECONDS>=600`, not a smaller expectation.

**llama.cpp host backend — GB10 lessons (FF711 campaign, 20260809)**
- **`CTX = CTX_PER_SLOT * NP` in the launcher is a trap.** Raising `NP` alone silently doubles total
  context and KV. `NP=32` at the default 12288/slot → ctx 393216, ~25 GiB KV, which **over-commits
  unified memory into swap** on the 121 GiB box: throughput collapsed (c16 63.5 → 36.3) and degraded
  *between* benches (c1 18.75 → 14.19) as swap kicked in. It is also two changes at once. Hold total
  ctx constant when sweeping slot count (`NP=32 CTX_PER_SLOT=6144`).
- **Decode is bandwidth-bound and you can verify it arithmetically.** Dense Q5_K_M 27B, MTP OFF:
  21.18 GB/token × 12.03 tok/s = **255 GB/s ≈ 93% of the GB10's 273 GB/s peak**. There is no engine
  headroom at c1 without speculation. Quant scaling follows the bytes: Q5→Q6 is +13.5% bytes and
  measured −11.5% c1 (predicted −11.9%).
- **MTP trades bandwidth efficiency for tokens.** With MTP on, *apparent* bandwidth drops (~172 GB/s)
  because the verify pass computes 3 positions instead of 1 plus the draft head — but net c1 is
  **+58.7%**. Don't read the lower apparent bandwidth as a regression.
- **Speculation depth optimum moves shallower as batch grows.** Draft 1→3: accepted length rises
  1.78→2.69 while acceptance falls 0.778→0.564. Best c1 at depth 3, best c16 at depth 1. Per-request
  `draft acceptance = …` lines in the server log are the ground truth — aggregate them per run
  before theorising about why a quant or depth won.
- **Cross-session c16 drift ~10% on this box** (same config: tune-loop median 63.51 vs finalize
  70.32; sample counts and output lengths matched, so not a sampling artifact). Suspected page-cache
  /memory state after cycling several 18–24 GB GGUFs. **This exceeds the +3% KEEP rule** — treat
  small c16 deltas across sessions as *not separable*, and prefer c1 (stable to ~1.4%) when the
  candidate's effect should show there.

**Spec-decode is NOT automatically greedy-lossless — check per engine**
- vLLM MTP/draft is greedy-lossless (scores carry over; that's why generative gates suffice there).
- **antirez/ds4 DSpark is NOT**: upstream README states a long greedy DSpark run "may diverge from a
  run without DSpark after an otherwise valid accepted block" (not a reduced-precision mode, but
  numerically different). `--dspark-strict` / `--quality` keep target-only decode for reproducibility.
  → any DSpark config needs **its own Gate 2**, not the baseline's.

**Adapter gotcha**
- `adapter.sh info/peakmem` are called standalone (no runbook sourced), so they read the image
  from the running container, not `$VLLM_IMAGE`. The image has `python3`, not `python`.
- `vllm serve --help` is paginated in v0.22.0 → use `--help=all` or `--help=<flag>`.

**GB10 HANG under sustained high concurrency (2026-06-13) — important**
- The full 180s/stage baseline **deadlocked at the c32 stage**: vLLM went 444→**0.0 tok/s with 32
  reqs stuck (Waiting:0)**, GPU wedged at **96% util / 15 W** (~constant), no logs for ~29 min.
  The 30s validation slipped through c32; sustained load wedged it. **`adapter down` freed the GPU
  instantly — no reboot.** So the hang is container-scoped and recoverable.
- Monitoring added to `bench.sh`: a **stall-watchdog** (trips after `STALL_SECS`=90 of vLLM
  "generation throughput: 0.0 … Running: N") + a **hard `timeout`** backstop → on hang it kills
  guidellm, writes a `status=crash` row, and `adapter down`s for clean recovery. A hang is now a
  fast logged data point, not a 40-min stall.
- **PARTIALLY mitigated by per-level isolation — NOT resolved (corrected 20260818).** Running each
  concurrency level as its own GuideLLM call preserves completed levels on a hang AND stopped the
  **c32** case reproducing (full 180s c32 then ran clean, chat c32=687.7). The original note claimed
  this RESOLVED the wedge. **It did not.** An audit of every `status=crash` row found **10 wedge
  events on this node**, nine of them AFTER per-level isolation was in place, spanning **four vLLM
  versions (0.22.0/0.23.0/0.24.0/0.25.0)** and four models (Qwen3-8B-NVFP4 dense, Qwen3.6-35B-A3B
  MoE, Nemotron-3-Super-120B MoE, 35B-A3B-Fast), 2026-06-13 → 2026-07-12. Level distribution:
  **c32 ×1, c16 ×7, c1 ×2** — i.e. it fires at **concurrency ONE**, so batch occupancy is not the
  trigger and "sustained high concurrency" in this note's title is misleading. Power at wedge
  15–30 W vs 33–44 W healthy. The watchdog is the real mitigation, not the isolation.
- **UPSTREAM = vLLM issue #43885** (open, GB10-specific, `get_output()` spin-loop on a stuck CUDA
  stream; their signature: 96% util at 19 W vs 36 W healthy — ours 96%/15 W). **If this wedge happens
  again: reference #43885 and RUN THE FORENSICS** before the watchdog tears the container down —
  `py-spy dump --native --pid $(pgrep -f 'VLLM::EngineCore')` is the one artefact that would upgrade
  our report from symptom-matching to evidence, plus `nvidia-smi -q` and `docker logs --tail 500`.
  Full protocol, our 10-event table, and a ready-to-post draft comment (deliberately NOT posted,
  user decision 20260818) live in **`research/upstream/vllm-43885-gb10-wedge.md`**. Verify the
  py-spy invocation works BEFORE the next wedge — the capture window is short and rare.
  Related: **#49210** (EngineCore livelock, 100% CPU, MTP + xgrammar — our tracked three-way bug),
  **#50934** (GB10 sm_121 CUDA misaligned address, NVFP4 + Marlin MoE + MTP), **#43702** (RFC:
  non-blocking core loop — confirms the engine core BLOCKS when idle, so EngineCore at ~100% CPU
  during active serving is EXPECTED work, not a spin; the pathological cases all show **zero
  throughput**, which is the discriminator).

**First green run — Qwen3-8B-NVFP4 Marlin baseline (2026-06-13)**
- Validation (30s/stage) output tok/s: c1≈42, c4≈145, c8≈250, c16≈358, c32≈426 — c1 matches
  NVIDIA's Llama-3.1-8B-NVFP4 ≈38.7 calibration. Path confirmed in logs: `MarlinNvFp4LinearKernel`,
  `quantization=compressed-tensors` (auto), `FLASH_ATTN` (FA2), KV dtype auto→bf16, util 0.5 →
  51.2 GiB KV / 372k tokens. `peak_gb` proxy ≈67 GB system-used while serving.
- Surprising: with auto KV (bf16) vLLM picked **FLASH_ATTN**, not FlashInfer — so `--kv-cache-dtype
  fp8_e4m3` (which FA can't do on sm_121) will *switch* the attention backend. Treat KV-dtype and
  attention-backend as a coupled tuning pair.

**Workflow**
- probe → `gen_baseline.py <model>` → edit runbook → `serve.sh <runbook>` → `bench.sh <runbook>`
  → `aggregate.py`. Local vLLM source for grepping fast-moving code: `source/vllm` (gitignored).
