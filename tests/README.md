# tests/ — the acceptance suite for the measurement-validity layer

The binding spec is [`docs/validity-contract.md`](../docs/validity-contract.md). **Every threshold
in its §3 and §4 is a test case here**, both sides of every boundary. This suite is the acceptance
gate for issue #1 §1: if it is green with no skips, the layer does what the contract says.

This is the repo's first test suite, so it also sets the convention. Two rules shaped it:

- **Hermetic.** No network, no container runtime, no server, no accelerator. The box is a shared
  single-GPU lab that may be serving right now (contract §8), and a benchmark harness whose tests
  need the hardware they are testing can never be run when it matters. The whole suite is ~0.5 s.
- **Zero dependencies.** Python's stdlib `unittest`, driven by bash. Charter rule 4 allows bash or
  python via `uv`/`uvx`; nothing is installed, nothing is pinned, nothing can rot.

## Running it

```bash
tests/run.sh                              # everything, verbose
tests/run.sh -q                           # dots only
tests/run.sh test_roofline test_status    # named modules
AHL_TEST_STRICT=1 tests/run.sh            # a SKIP fails the run  <- use this post-merge
```

`run.sh` uses `uv run --no-project --offline python` (falling back to `python3`), so it never
touches the network and never pulls the project's heavy `guidellm`/`lm-eval` dependencies.

### Green-on-skip, and why `AHL_TEST_STRICT=1` matters

The suite was written **before** the implementation, by a different agent, against the contract
alone. Until `scripts/lib/validity.py`, `scripts/lib/validity.sh` and
`scripts/migrate_results_tsv.py` land, every test that targets them **skips with a message naming
exactly what is missing**, and `run.sh` exits 0. That keeps the pre-merge tree green without
pretending anything was verified.

After the merge that default is the wrong one: a skip means *this contract rule was not checked*,
which is indistinguishable from a pass in a plain `unittest` summary. `AHL_TEST_STRICT=1` turns
any skip into a failure and prints the reasons. **The acceptance run is the strict one.**

## What each module pins down

| module | pins down |
|---|---|
| `test_verdicts.py` | §3 verdict tokens. The three historical defects as fixtures; the `MIN_DATA=5` / `MIN_SUCCESSFUL=20` boundaries at 4/5/19/20; `no_data` ⊻ `low_sample`; the 9.9% vs 10.1% monotonicity edge; the 10% errored-ratio edge and its denominator; and the subtlest rule in the contract — **unrun (`na`) levels are skipped, never scored as zero**, so a lean `LEVELS_SET=1,16` run is `ok`, not `no_data` for c4/c8/c32. |
| `test_roofline.py` | §4. The ceiling at 8735 vs 8737 tok/s at c16 on a 273 GB/s node; that it scales per level; that a known bytes/token tightens it; and that a node profile **without** `gpu.mem_bw_gbs` **skips** the check rather than failing it or inventing a bandwidth. Plus the named defaults (SAFETY 2.0, MIN_MODEL_GB 1.0, MIN_DATA 5, MIN_SUCCESSFUL 20). |
| `test_encodings.py` | §2 `req_counts` and `knobs`. Round-trip stability (`parse -> format -> parse`), ascending level order, `na` for unknown, the documented `ok/incomplete/errored` triple order, and that no value can carry a tab or a newline into a TSV. |
| `test_status.py` | §5/§6 precedence. `void` outranks `suspect`; `crash` outranks both and still records its verdict; a clean row keeps the caller's `STATUS`; the vocabulary is exactly the six words of §6; the validity exit code is 4. |
| `test_schema.py` | §2 header (exactly 23 columns, contract order, `status notes data` tail intact) and §7 migration: a legacy 20-column row keeps **every original value byte-identically in its new position**, historical `status` is not rewritten, and the migration is idempotent. |
| `test_real_bundles.py` | The reality check. Real minimized bundles from this node: a healthy run must come back **`ok`** (a layer that flags good runs gets switched off within a week), the 2-request c32 must be `void`, the 449,358 row must be `over_roofline`. Plus fixture-integrity guards so a silently edited fixture cannot make the suite lie. |
| `test_wiring.py` | §1/§5 structure, read statically because `bench.sh` cannot be executed here: the header no longer exists in `bench*.sh`/`aggregate.py`, the bash shim delegates instead of re-implementing, `bench.sh` keeps exit 3 for crash and gains exit 4 for invalid, the failing row is still written, and `promote.sh`/`run_experiment.sh`/`aggregate.py` know the new statuses. |

## Adding a case — the convention

1. **Name the contract clause in the docstring.** Every test says which §, and quotes the rule when
   the wording is what is being pinned. A test whose motivation is not in the spec is a test the
   next person will delete.
2. **Assert both sides of a boundary.** `4` and `5`, `19` and `20`, `9.9%` and `10.1%`. One-sided
   threshold tests pass against an implementation that never fires at all.
3. **Skip, don't fail, when the target is absent** — via `api.require_validity` / `api.attr` /
   `api.require_file`. The message must name what is missing and who owns it.
4. **Put the failing value in the assertion message.** `f"...; got {v}"`. `Verdict.__repr__` prints
   validity, status and req_counts together, which is usually the whole diagnosis.
5. **Fixtures are minimized real bundles, never invented ones**, wherever a real one exists. Use
   `tests/tools/minimize_bundle.sh` and record the source in `tests/fixtures/PROVENANCE.md`.
   Synthetic levels (`api.level_json`) are for cases with no real example — boundary values,
   corrupted files. They write the counts in **both** places real bundles carry them
   (`metrics.request_totals` and `metrics.<m>.<outcome>.count`) so a test never depends on which
   one the implementation reads.
6. **Never read `results/**/data/`.** It is gitignored, absent from a fresh clone, and changes
   whenever the lab runs. `test_wiring.py` enforces this.
7. **Never invoke docker, a server, `guidellm`, `lm-eval`, or the GPU.** Also enforced.

## If the implementation's API does not match

Everything this suite had to guess about Python signatures lives in **one file**,
`tests/ahl_test/api.py`: the callable-name aliases, the parameter-name aliases, and the
return-shape normalizer. If the merged implementation names things differently, edit the alias
tables there — not the tests. The surface the suite prefers:

```python
# scripts/lib/validity.py
COLUMNS: list[str]        # 23 names, contract §2 order
HEADER:  str              # "\t".join(COLUMNS)
MIN_DATA = 5 ; MIN_SUCCESSFUL = 20 ; SAFETY = 2.0 ; MIN_MODEL_GB = 1.0
STATUSES = {"measured", "keep", "discard", "crash", "suspect", "void"}
EXIT_INVALID = 4

def assess_bundle(bundle_dir, levels, node_profile=None, status="measured",
                  bytes_per_token_gb=None):
    """bundle_dir holds level_c<N>.json; `levels` is the list of levels that were RUN.
    Returns an object (or dict) with .validity, .status (post-downgrade) and .req_counts."""

def format_req_counts(mapping) -> str ;  def parse_req_counts(s) -> mapping
def format_knobs(mapping)      -> str ;  def parse_knobs(s)      -> mapping
```

```bash
# scripts/lib/validity.sh
validity.sh header      # prints the 23-column header, tab-separated
```

`scripts/migrate_results_tsv.py` must accept a `results.tsv` path and rewrite it in place,
idempotently (`--write` / `--in-place` / `-i` are also accepted by the test driver).
