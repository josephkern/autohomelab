# Measurement-validity contract (v1)

The binding spec for the §1 work of [issue #1](https://github.com/josephkern/autohomelab/issues/1).
Authored 2026-08-19 as the fixed interface ten parallel agents build against. **Implement to this
spec exactly.** If you believe a rule here is wrong, implement it anyway and say so in your report —
adjudication is the orchestrator's call, not a unilateral edit.

## 0. Why

The project's only product is measurements. Three defects in one session each wrote
`status=measured` rows that were wrong and raised no error: a c32 figure averaged over **2**
completed requests, a `tps_c16` of **449,358** from a dead endpoint, and a spec-decode config
scored by a loglikelihood task returning `NaN` for 56,168 requests. The failure mode of this
codebase is not a crash, it is a plausible number. This contract adds the missing validity layer.

## 1. Single source of truth

`scripts/lib/validity.py` is the **only** implementation of the rules. `scripts/lib/validity.sh`
is a thin bash shim for the `bench*.sh` callers; it must not re-implement any rule. Four files
currently hard-code the header string (`bench.sh`, `bench_ds4.sh`, `bench_llamacpp.sh`,
`aggregate.py`) — after this work the header exists once, in the library, and is consumed from
there.

## 2. `results.tsv` schema (23 columns)

```
run_id  commit  node_fp  model  shape  backend  config_hash  script
load_s  max_s  seed  tps_c1  tps_c4  tps_c8  tps_c16  tps_c32  peak_gb
req_counts  validity  knobs  status  notes  data
```

Three new columns, inserted after `peak_gb`, before `status` (the trailing `status notes data`
tail is preserved so eyeballing a row is unchanged):

- **`req_counts`** — per-level request outcome, `ok/incomplete/errored`, semicolon-joined, only
  for levels actually run: `c1:41/0/0;c16:118/4/0`. `na` when unknown (historical rows with no
  retained bundle). This is the column that makes validity auditable without the raw bundle.
- **`validity`** — `ok`, or a `+`-joined list of verdict tokens (§3): `low_sample+nonmonotonic`.
- **`knobs`** — the full effective knob set resolved at run time, `k=v` comma-joined:
  `levels=1,16,max_s=180,seed=42,prompt=512,output=256,stall=90,ltimeout=480,gllm=0.6.0`.
  Rationale: a baseline run at `MAX_SECONDS=600` and a finalize run at the 180 default were
  indistinguishable in the journal until someone compared curve shapes.

Column order is fixed. Values are never empty — use `na`. No tabs or newlines inside a value.

## 3. Verdict tokens

Computed per row from the per-level GuideLLM JSON.

| token | rule | severity |
|---|---|---|
| `ok` | all checks pass | — |
| `no_data` | a run level has `successful < AHL_MIN_DATA` (default **5**), or its `level_c<N>.json` is missing/unparseable | fatal |
| `low_sample` | a run level has `successful < AHL_MIN_SUCCESSFUL` (default **20**, per the AGENTS.md rule of thumb) | suspect |
| `over_roofline` | a level's tok/s exceeds the physical ceiling of §4 | fatal |
| `nonmonotonic` | a higher concurrency level is more than **10%** below a lower one (plateau and noise are expected on this box; only a real inversion trips it) | suspect |
| `errored` | a level has `errored > 10%` of `successful + errored` | suspect |

`no_data` and `low_sample` are mutually exclusive — report the more severe. Verdicts are computed
over **run** levels only; `na` (unrun) levels are skipped, never treated as zero.

Note for implementers: of the three historical defects, the 2-request c32 is caught by `no_data`,
the 449,358 row by `over_roofline`, and the coder inversion (c8 70.88 > c16 68.88, a 2.8% drop) is
caught by `no_data` and **not** by `nonmonotonic` — the 10% threshold is deliberately loose because
`c8 > c16` within noise is a real, legitimate result on a bandwidth-bound box. Sample count is the
primary detector; monotonicity is a secondary one.

## 4. Physical ceiling (roofline)

Decode is memory-bandwidth-bound. With batch size B, one decode step reads the weights once and
emits B tokens, so aggregate throughput cannot exceed

```
ceiling(level) = SAFETY * level * (mem_bw_GB_s / bytes_per_token_GB)
```

- `mem_bw_GB_s` comes from `node_profile.json` -> `gpu.mem_bw_gbs` (new field; the probe must
  record it — 273 for GB10/LPDDR5X).
- `bytes_per_token_GB` is the model's active weight bytes per token when known; when unknown fall
  back to `AHL_MIN_MODEL_GB` (default **1.0**), which yields a loose but sound bound.
- `SAFETY` defaults to **2.0**. This bound is meant to refute the physically impossible
  (449,358 tok/s implies 0.0006 GB/token on a 273 GB/s box), not to be tight. A tight bound would
  produce false positives and get ignored.

If `mem_bw_gbs` is absent from the node profile, the check is **skipped** and the row records
`validity=...` without `over_roofline` — never invent a bandwidth number.

## 5. Enforcement

Decided: **record and flag, exit non-zero.** A failing run is still written to `results.tsv` — the
evidence must survive in the committed journal, not only in the gitignored bundle — but:

- `status` is downgraded: any fatal verdict -> **`void`**; any suspect verdict -> **`suspect`**;
  otherwise unchanged (`measured`, or the caller's `STATUS`).
- `bench.sh` exits **4** on a validity failure (distinct from the existing 3 = crash/hang, so
  callers can tell "the box broke" from "the numbers are not citable"). A crash still wins: an
  already-`crash` row keeps `status=crash` and its verdict is recorded in `validity`.
- Downstream consumers must treat `void` as non-existent data and `suspect` as non-citable:
  `promote.sh` refuses to promote a config whose supporting rows are `void`/`suspect`,
  `run_experiment.sh` refuses to compute a median over them, `aggregate.py` filters them out of
  the default view.

## 6. Status vocabulary

`measured` (valid, unjudged) · `keep` · `discard` · `crash` (engine wedge/hang) · **`suspect`**
(measured but invariants question it) · **`void`** (not data; must not be cited). `measured` no
longer means "a row exists" — it means the invariants passed.

## 7. Historical rows

313 rows across 15 campaigns; 693 `level_c*.json` bundles are retained locally. Decided: backfill
`req_counts`/`validity`/`knobs` where the bundles allow, publish an audit of what the invariants
say about published numbers, and **do not rewrite historical `status` values** — those are
adjudicated row by row by the orchestrator, because several are already cited in logbooks.

Bundles live under `results/**/data/` which is **gitignored and therefore absent from your
worktree**. Read them read-only from the main checkout at
`/home/jk/projects/dgx-homelab/results/...`; write only inside your own worktree.

## 8. Rules that still bind

Charter rule 4: helper scripts are `bash` or `python` via `uv`/`uvx` — no other languages, no
global pip. `set -euo pipefail` in every script. `.env` and `results/**/data/` are never committed.
No agent runs docker, serves a model, or touches the GPU: the box is a shared single-GPU lab and
may be serving right now.
