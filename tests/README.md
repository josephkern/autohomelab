# tests/ — the acceptance suite for the measurement-validity layer

The binding spec is [`docs/validity-contract.md`](../docs/validity-contract.md) — **v1.3**. That
file is an amendment ledger and later sections overrule earlier ones: the v1.2 amendment block wins
over v1.1, the closing **"v1.2 status"** section wins over the amendment block (A2 and A4 were both
wrong as written and were re-adjudicated after measuring), and the closing **v1.3** section wins
over all of it (`keep` retired, `discard` redefined as a signed §7 adjudication). The tests follow
the shipped forms — `survivorship` = `incomplete > ok`, `errored_fatal` as its own base token, a
five-word `STATUS_VOCAB` — not the amendment text. **Every threshold in its §3 and §4 is a test
case here**, both sides of every boundary. This suite is the acceptance gate for issue #1 §1: if
it is green with no skips *and `tests/mutate.sh` reports no survivors*, the layer does what the
contract says.

**Current state: `AHL_TEST_STRICT=1 tests/run.sh` = 279 tests, 0 skips, ~45 s. `tests/mutate.sh` =
38 mutations, 38 killed, 0 survivors, 0 N/A.**

Those are two different claims, and the second one is why the harness exists. Mutation testing of
the v1.1 suite found **16 surviving mutations**: every v1.1 amendment and every enforcement path
could be deleted or inverted with 121/121 still green. A suite that agrees with the library is not
a test of the library.

The repo's scar makes this concrete. **Five** separate guards here have been *correct* and
*unreachable* — `suite.sh`'s reasoning-before-spec-decode `if/elif` (which burned a 75-minute,
56,168-request NaN eval); `bench.sh` reading verdict globals nothing ever set; `--node-profile`
never being passed, so the roofline was dead on the primary bencher while the two host benchers ran
it; contract v1.2's own `incomplete > level`, which GuideLLM makes unsatisfiable; and a `trap` that
could not fire until `LEVEL_TIMEOUT`, because bash defers a trap until the foreground command ends.
Two of the five carried a comment asserting they were live. **"This condition is correct" and "this
condition is reached" are different claims; only the second one needs an execution trace.** That is
why the wiring tests run the real scripts against stubs, why `test_interrupt_recovery.py` actually
*sends the signal* mid-level, and why mutation coverage is part of the gate rather than a nicety:
a mutation that does not turn the suite red proves the rule it broke was never exercised.

**And a third claim, learned the hard way in the same wave: TEST FAITHFULNESS.** A green assertion
can encode the bug — one selftest case asserted that an uncatalogued image should take its version
from a trailing runbook comment, which was exactly the `promote.sh` defect. And a "surviving"
mutation can be a bad experiment rather than a coverage gap: one survivor here died as soon as the
case set its env override *before* sourcing the library, because this library reads env at **call**
time. Correctness, reachability and faithfulness need three different kinds of evidence; a green
suite gives you none of them by itself.

This is the repo's first test suite, so it also sets the convention. Two rules shaped it:

- **Hermetic.** No network, no container runtime, no server, no accelerator. The box is a shared
  single-GPU lab that may be serving right now (contract §8), and a benchmark harness whose tests
  need the hardware they are testing can never be run when it matters. The whole suite is ~45 s,
  most of it the wiring and interrupt tests, which run the real
  `bench.sh`/`aggregate.py`/`promote.sh` against stubbed children rather than reading them as text.
- **Zero dependencies.** Python's stdlib `unittest`, driven by bash. Charter rule 4 allows bash or
  python via `uv`/`uvx`; nothing is installed, nothing is pinned, nothing can rot.

## Running it

```bash
tests/run.sh                              # everything, verbose
tests/run.sh -q                           # dots only
tests/run.sh test_roofline test_status    # named modules
AHL_TEST_STRICT=1 tests/run.sh            # a SKIP fails the run  <- use this post-merge

tests/mutate.sh                           # the mutation harness: break each rule, expect RED
tests/mutate.sh -l                        # list the mutations
tests/mutate.sh survivorship_deleted      # just one
```

**The acceptance run is both.** `AHL_TEST_STRICT=1 tests/run.sh` says the rules hold;
`tests/mutate.sh` says the suite would notice if they stopped holding. The harness takes several
minutes because it is deliberately serial (see below); the suite itself is ~45 s.

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
| `test_verdicts.py` | §3 verdict tokens. §0 defects (a) and (b) as fixtures; the `MIN_DATA=5` / `MIN_SUCCESSFUL=20` boundaries at 4/5/19/20; `no_data` ⊻ `low_sample`; the 9.9% vs 10.1% monotonicity edge; the 10% errored edge and its denominator; **level tagging asserted on `.tagged`**; **adjacency at 3+ levels** (at two levels adjacent and pairwise-all are indistinguishable, which is how reverting to `itertools.combinations` stayed green); the `na` (never attempted) vs `hang` (wedged) distinction; and the subtlest rule in the contract — **unrun levels are skipped, never scored as zero**. |
| `test_v12_amendments.py` | The v1.2 block. A1 the token clause is **gone** (an absurd `AHL_MIN_TOKENS` must change nothing) · A2 `survivorship` as finally adjudicated — majority discard, `incomplete > ok`, with the `incomplete == ok` boundary and the two withdrawn forms asserted NOT to fire · A3 `no_output` (zero / negative / missing / NaN tok/s with successful requests) · A4 `errored_fatal` as a distinct base token above 50%, both sides of the boundary · A5 `na` is never `ok`, including `parse_validity("na")` and an empty bundle · A10 the CLI and `assess_bundle` agree on the same evidence, including a stale `level_c8.json`. |
| `test_roofline.py` | §4. The ceiling at **13103 vs 13105** tok/s at c16 on a 273 GB/s node (SAFETY **3.0**), plus a guard asserting the pair still brackets `SAFETY * 16 * 273` — the old pair said 8735 with a comment reading `2.0 * 16 * 273`, so half of it sat 33% below the real threshold and constrained nothing. Per-level scaling; a known bytes/token tightening it; and a profile **without** `gpu.mem_bw_gbs` **skipping** the check rather than guessing. |
| `test_encodings.py` | §2 `req_counts` and `knobs`. Round-trip stability, ascending level order, `na` for unknown, the `ok/incomplete/errored` triple order, and that no value can carry a tab or newline into a TSV. Plus the `|` list separator asserted on an actual Python list — the round-trip tests only ever hand the encoder a pre-joined string, so they pass unchanged with the joiner set back to a comma. |
| `test_status.py` | §5/§6/§7 precedence and the **v1.3 vocabulary**. `void` outranks `suspect`; `crash` outranks both and still records its verdict; a clean row keeps the caller's `STATUS`; the vocabulary is exactly the **five** words of §6 and `check_status()` **raises on `keep`** with its retirement notice; a hand-set `discard` without an `adjudicated@YYYYMMDD who: reason` stamp (reason ≥ 12 chars) is refused, and a stamp that parses but says nothing is not a signature; the validity exit code is 4 and a refused invocation is **2**, off the ladder. |
| `test_schema.py` | §2 header (exactly 23 columns, contract order) and §7 migration: a legacy 20-column row keeps every original value byte-identically in its new position, historical `status` is not rewritten, and the migration is idempotent. |
| `test_real_bundles.py` | The reality check on minimized real bundles from this node. **Five healthy fixtures** — chat, coder, a five-level sweep, llama.cpp and ds4 — must all come back `ok`; the 2-request c32 must be `void`; the 449,358 row must be `over_roofline` and `errored_fatal`. Plus fixture-integrity guards so a silently edited fixture cannot make the suite lie. |
| `test_bench_enforcement.py` | §5 and A6 **executed**: the real `bench.sh` runs in a scratch repo with stubbed children, and the assertions are on the emitted row, the exit code and the call log — status downgrade, exit 3 vs 4, `suspect` alone still exiting 4, the row surviving its own verdict, `--node-profile` reaching the library, the roofline firing on the vLLM path and being skipped without a bandwidth figure, and failing **closed** when the library errors. |
| `test_consumers.py` | §1 and §5 **executed**: the header's single definition (rename the library's last column and watch `validity.sh` and `bench.sh` follow), and `aggregate.py`'s default view holding back void / suspect / crash / `na` / *and a `measured` row whose `validity` is fatal* — the status-only filter's blind spot. |
| `test_reachability.py` | Runs `scripts/citability_selftest.sh` (**102 checks**) as part of the suite. It already exercised `promote.sh`, `suite.sh`, `validate.sh` and both runners the right way — by executing them — but nothing ran it, which is why four enforcement mutations survived. |
| `test_interrupt_recovery.py` | **59 tests, every one of which SIGNALS the real `bench.sh` mid-level** (a marker file marks "provably inside this level", so nothing is a timing guess). An interrupted sweep must still leave a row carrying `incomplete_run`; the write is the atomic unit in both directions (a signal at any of the six command boundaries inside `emit_row` must not lose the row of a sweep that FINISHED); no process outlives the run, and the stall-watchdog must not be orphaned into firing a box-wide `pkill` at somebody else's bench; a signal must not erase a real wedge; an escalating supervisor is ordinary; and the host benchers record an interrupted shape too — the orphan bundle that motivated all of this came from `bench_llamacpp.sh`. |
| *(Gate 2, outside this suite)* | `scripts/eval_validity_selftest.sh` — **96 checks** on `scripts/eval_validity.py`, the Gate-2 acceptance predicate (contract A9): `no_score` / `nonfinite` / `short_sample` fatal, `zero_score` / `no_samples` suspect, task-tagged verdicts, the 16-column `accuracy.tsv`, and **execution traces proving every Gate-2 branch is reachable for all four runbook variants** — neither / reasoning / spec-decode / **both**, the combination that the original `if/elif` could not reach. Hermetic, synthetic bundles, no GPU. |
| *(host identity, outside this suite)* | `scripts/hostcfg_selftest.sh` — **108 checks** on `scripts/lib/hostcfg.sh`, the `hp3-` config identity for ds4 / llama.cpp. Feeds the library a **fabricated `/proc`** via `AHL_PROC`, so it needs no server, no root and no GPU; asserts that Gate 2 (`eval.sh`) and Gate 3 (the benchers) hash the *same document* for one process, which is the whole point of the layer. |
| *(private set, outside this suite)* | `scripts/eval_private_selftest.sh` — **261 checks** on the tier-4 held-out runner, most of them leakage regressions: an adversarial verifier found twelve paths through the first version while its own 139-check selftest was green. |
| *(statistics, outside this suite)* | `scripts/power_selftest.sh` — **77 CLI checks** (**71** in a worktree, where `results/**/data/` is absent; set `AHL_POWER_DATA_ROOT` to the main checkout) plus 68 numeric self-checks inside `power.py selftest`, each hand-checkable against a published value. |
| `tools/mutations.py`, `mutate.sh` | The harness (contract A8). **38 mutations**: every §3/§4 rule, every enforcement link, and the interrupt/watchdog paths. |

## The mutation harness

`tests/mutate.sh` copies the repo into a scratch directory **per mutation**, applies one mutation
to the copy, runs `tests/run.sh` there, and reports any mutation the suite failed to notice.

Three properties are deliberate:

- **The working tree is never mutated.** Every edit lands on a `tar`-piped copy under `$TMPDIR`.
- **It compares failing-test SETS against an unmutated baseline**, not exit codes. If the baseline
  is red for an unrelated reason, an exit-code comparison scores every mutation "killed" and prints
  a clean sheet — the same false green the whole exercise is about.
- **It is serial.** The first attempt at this raced two mutators over one directory and reported
  everything red, which is that artifact wearing the opposite colour.

A **survivor is a hypothesis, not a finding**: before writing a test for one, confirm the mutant
really breaks the rule it names. One survivor in the 20260820 wave was an artefact of *when* the
case set its env override (this library reads env at call time), not of missing coverage.

**And check the table is COMPLETE before reading it as clean.** The harness used to copy the 5.1 GB
`.venv` per mutation; one run died mid-table on `file changed as we read it` while another agent
wrote into the tree — a silent `set -e` abort that printed a short table with no failures, which
looks exactly like a clean sheet. A copy is now 4.8 MB and a failed copy is a loud error. Count the
rows against `tests/mutate.sh -l`.

A mutation whose pattern no longer matches is reported **N/A**, never green: that means the
implementation spells the rule differently and the pattern needs updating, not that the rule is
covered.

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
8. **A wiring test EXECUTES the path.** A substring grep is not a test: `assertRegex(src, "knobs")`
   passes on a docstring, and `_needs("promote.sh", "void", "suspect")` passed on a comment saying
   they were unhandled. Use `ahl_test.scratch.ScratchRepo` — it runs the real script against
   logging stubs — and assert on the emitted row, the exit code, and the call log.
9. **Assert on `.tagged` whenever the LEVEL matters.** `Verdict.tokens` returns base names only,
   on purpose: it used to return the tagged token *and* its bare base, which made the suite
   structurally unable to notice whether level tagging existed at all.
10. **Name the test after what it tests.** Three tests were called `test_c_*` after §0 defect (c),
    the NaN loglikelihood eval, while testing a missing level JSON — so a reader running the suite
    saw all three motivating defects green. Nothing in this module can catch defect (c); it is a
    Gate-2 failure (§0 scope limit, v1.2 A9). They are now `TestMissingLevelJson`. **This is the
    exact mechanism by which a project comes to believe it is protected when it is not.**
11. **Add a mutation with the rule.** A1.2/A8: if breaking your rule does not turn the suite red,
    the rule is untested. Add it to `tests/tools/mutations.py` and run `tests/mutate.sh <name>`.

## If the implementation's API does not match

Everything this suite had to guess about Python signatures lives in **one file**,
`tests/ahl_test/api.py`: the callable-name aliases, the parameter-name aliases, and the
return-shape normalizer. If the merged implementation names things differently, edit the alias
tables there — not the tests. The surface the suite prefers:

```python
# scripts/lib/validity.py
COLUMNS: list[str]        # 23 names, contract §2 order
HEADER:  str              # "\t".join(COLUMNS)
MIN_DATA = 5 ; MIN_SUCCESSFUL = 20 ; SAFETY = 3.0 ; MIN_MODEL_GB = 1.0
STATUS_VOCAB = ("measured", "discard", "crash", "suspect", "void")   # §6 v1.3: `keep` is RETIRED
STATUSES = STATUS_VOCAB                          # legacy alias, same five words
EXIT_INVALID = 4 ; EXIT_USAGE = 2        # 2 = the invocation was refused, outside the 3>4>1>0 ladder

def check_status(status, notes=None) -> str      # raises on `keep`, or on an unsigned `discard`
def parse_adjudication(notes)                    # -> (YYYYMMDD, who, reason) | None

def assess_bundle(bundle_dir, levels, tps=None, node_profile=None, status="measured",
                  bytes_per_token_gb=None):
    """bundle_dir holds level_c<N>.json; `levels` is the list of levels that were RUN; `tps`
    maps level -> the RAW results.tsv cell, which is the only thing that distinguishes a level
    that was never attempted (`na`) from one that wedged (`hang`).
    Returns an object (or dict) with .validity, .status (post-downgrade) and .req_counts."""

def format_req_counts(mapping) -> str ;  def parse_req_counts(s) -> mapping
def format_knobs(mapping)      -> str ;  def parse_knobs(s)      -> mapping
```

```bash
# scripts/lib/validity.sh
validity.sh header      # prints the 23-column header, tab-separated
```

`scripts/migrate_results_tsv.py` must accept a `results.tsv` path and rewrite it in place,
idempotently (`--apply` is the write flag; `--write` / `--in-place` / `-i` are aliases).
