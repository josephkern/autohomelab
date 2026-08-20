#!/usr/bin/env python3
"""The mutation catalogue for `tests/mutate.sh` (contract v1.2 A8).

    "A mutation harness is part of the suite. A rule with no mutation that turns the suite red
     is an untested rule."

Each entry breaks ONE contract rule or ONE enforcement link, the way a careless edit or a bad
merge would. The harness applies it to a scratch COPY of the repo (never the working tree), runs
`tests/run.sh` there, and compares the set of failing tests against the unmutated baseline. A
mutation that produces no NEW failure is a **survivor**: the rule it breaks is not really tested.

Comparing failure SETS rather than exit codes is deliberate. If the baseline is red for unrelated
reasons — as it was while v1.2 was still landing — an exit-code comparison scores every mutation
"killed" for the wrong reason, which is the same flavour of false green this exercise exists to
remove.

A mutation whose pattern is not present is reported NOT-APPLICABLE, never green: that is the
honest answer for a rule the implementation spells differently, and it is a prompt to update the
pattern rather than a pass.

Two entries in the original 16 were about rules that have since changed, and are re-pointed here
rather than dropped:

  * the v1.1 token-budget clause is deleted outright by v1.2 A1, so `out_tokens <= 0` guards
    nothing. Its replacements are `request_floor_dropped` (A1 made the request floor the WHOLE
    low_sample rule) and `no_output_guard_weakened` (the finiteness guard that now does that job).
  * `survivorship` was re-adjudicated twice on measurement and is now majority-discard
    (`ok > 0 and incomplete > ok`), so the mutations target that form.

Usage (normally via tests/mutate.sh):
    python3 tests/tools/mutations.py list
    python3 tests/tools/mutations.py describe <name>
    python3 tests/tools/mutations.py apply <name> <repo_root>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LIB = "scripts/lib/validity.py"
SHIM = "scripts/lib/validity.sh"
BENCH = "scripts/bench.sh"
PROMOTE = "scripts/promote.sh"
SUITE = "scripts/suite.sh"
AGGREGATE = "scripts/aggregate.py"

MUTATIONS: dict = {}


def mutation(name, target, why, *alternates):
    """Register one mutation. Each alternate is a list of (regex, replacement) edits; the first
    alternate whose every edit matches is the one applied."""
    MUTATIONS[name] = {"target": target, "why": why, "alternates": alternates}


# ══════════════════════════════════════════════════════════════════════════════════════════════
# The RULES — scripts/lib/validity.py
# ══════════════════════════════════════════════════════════════════════════════════════════════
mutation(
    "survivorship_deleted", LIB,
    "§3/A2: delete the survivorship verdict entirely.",
    [(r"found\.add\(tag_verdict\(\s*(?:V_SURVIVORSHIP|[\"']survivorship[\"'])[^\n]*\)",
      "pass")],
)

mutation(
    "survivorship_boundary_loosened", LIB,
    "A2: `incomplete > ok` becomes `>=`, which is the withdrawn v1.1 form — half the work "
    "discarded is not a majority, and v1.1's form is arithmetically `ok <= level`.",
    [(r"c\.ok > 0 and c\.incomplete > c\.ok", "c.incomplete >= c.ok")],
    [(r"c\.incomplete > c\.ok", "c.incomplete >= c.ok")],
)

mutation(
    "nonmonotonic_pairwise", LIB,
    "§3 v1.1: revert adjacency to pairwise-all — the exact semantics v1.1 withdrew, because a "
    "legitimate high-concurrency plateau then reads as an inversion.",
    [(r"zip\(curve, curve\[1:\]\)",
      '__import__("itertools").combinations(curve, 2)')],
)

mutation(
    "level_tagging_deleted", LIB,
    "§3 v1.1: `tag_verdict` returns the bare base always, so a thin c1 sentinel condemns the "
    "c16 objective again and no consumer can scope to the level it cites.",
    [(r'return "%s@c%d" % \(base, int\(level\)\)', "return base")],
    [(r'return f"\{base\}@c\{int\(level\)\}"', "return base")],
)

mutation(
    "unrun_level_guard_dead", LIB,
    "§3: an unrun level is scored as a zero instead of being skipped — this voids every lean "
    "LEVELS_SET=1,16 row in the project.",
    [(r"if counts\.missing and not published:", "if False:")],
)

mutation(
    "cell_published_always_true", LIB,
    "§3: collapse the `na` (never attempted) vs `hang` (wedged) distinction, so a level that "
    "was never run is judged as one that produced nothing.",
    [(r'return s not in \("", NA, "none", "null"\)', "return True")],
)

mutation(
    "request_floor_dropped", LIB,
    "A1: since the token-budget clause was deleted, `max(MIN_DATA, min(20, 4*level))` IS the "
    "low_sample rule. Drop it to zero and nothing is ever thin.",
    [(r"return max\(min_data, min\(cap, 4 \* int\(level\)\)\)", "return 0")],
)

mutation(
    "no_output_deleted", LIB,
    "A3: delete the throughput FLOOR, so a serve emitting zero tokens with 200 successful "
    "requests grades `ok` again.",
    [(r"found\.add\(tag_verdict\(\s*(?:V_NO_OUTPUT|[\"']no_output[\"'])[^\n]*\)", "pass")],
)

mutation(
    "no_output_guard_weakened", LIB,
    "A3: weaken the finiteness/<=0 guard so only a MISSING metric counts — 0.0 tok/s from 200 "
    "successful requests is admitted as a measurement. (The v1.2 stand-in for the v1.1 "
    "`out_tokens <= 0` guard, which A1 deleted along with its clause.)",
    [(r"if rate is None or rate <= 0:", "if rate is None and False:")],
    [(r"if self\.out_tokens is None or not math\.isfinite\(self\.out_tokens\) or "
      r"self\.out_tokens <= 0:", "if self.out_tokens is None:")],
)

mutation(
    "errored_never_fatal", LIB,
    "A4: drop the escalation, so a dead endpoint at 99.99% errored carries the same severity "
    "as one at 11%.",
    [(r"if err_rate > err_fatal:", "if False:")],
)

mutation(
    "errored_fatal_collapsed", LIB,
    "A4: give the fatal band the same base token as the suspect band, so severity stops being "
    "readable from the persisted `validity` string — which is all a consumer of a committed "
    "row has.",
    [(r'V_ERRORED_FATAL = "errored_fatal"', 'V_ERRORED_FATAL = "errored"')],
)

mutation(
    "na_is_ok_again", LIB,
    "A5: `na` collapses back onto `ok` — 'the library asserted the opposite of the contract, so "
    "any consumer that parsed before checking was wrong by construction'.",
    [(r"return \[V_NA\]", "return [V_OK]")],
)

mutation(
    "roofline_never_fires", LIB,
    "§4: the physical ceiling stops being computed, so the 449,358 tok/s row is data again.",
    [(r"return float\(safety\) \* lvl \* \(bw / bpt\)", "return math.inf")],
)

mutation(
    "min_data_floor_dropped", LIB,
    "§3: `AHL_MIN_DATA` = 5 is what catches §0 defect (a), the 2-request level. Drop it to 0.",
    [(r"^AHL_MIN_DATA = 5", "AHL_MIN_DATA = 0")],
)

mutation(
    "knobs_list_separator_reverted", LIB,
    "§2 v1.1 value encoding: put the comma back inside a list value, so a naive split(',') on "
    "the knobs column stops being correct.",
    [(r'_LIST_SEP = "\|"', '_LIST_SEP = ","')],
)

mutation(
    "discovery_reenabled", LIB,
    "A10: `assess_bundle` discovers stray level files again, so a stale level_c8.json from a "
    "previous shape is scored and the library disagrees with its own CLI.",
    # The signature DEFAULT, not a comment. An earlier version of this pattern matched
    # `discover=False` and hit only prose — it rewrote two docstrings, changed no behaviour, and
    # was duly reported as a survivor. A mutation that does not mutate is a false negative about
    # the tests, so patterns here must name executable text.
    [(r"discover: bool = False", "discover: bool = True")],
    [(r"scan_bundle\(bundle_dir, levels, tps, discover=False\)",
      "scan_bundle(bundle_dir, levels, tps, discover=True)")],
)

# ══════════════════════════════════════════════════════════════════════════════════════════════
# The ENFORCEMENT WIRING — the whole point of the layer
# ══════════════════════════════════════════════════════════════════════════════════════════════
mutation(
    "bench_status_downgrade_deleted", BENCH,
    "§5: delete `status=\"$STATUS_FLOOR\"`, so an invalid row is journalled as `measured`.",
    [(r'status="\$STATUS_FLOOR"', "true")],
)

mutation(
    "bench_exit4_deleted", BENCH,
    "§5: `return 4` becomes `return 0`, so no caller ever learns the row is not citable.",
    [(r'\[ "\$invalid" = 1 \] && return 4', '[ "$invalid" = 1 ] && return 0')],
    [(r"return 4\b", "return 0")],
)

mutation(
    "bench_check_validity_hardcoded_ok", BENCH,
    "§1/§5: `check_validity` answers `ok` without ever calling the library.",
    [(r"check_validity\(\) \{\n",
      'check_validity() {\n  VALIDITY=ok; REQ_COUNTS=na; STATUS_FLOOR=ok; return 0\n')],
)

mutation(
    "bench_check_validity_call_removed", BENCH,
    "§5: the call itself is gone; the row is written with fail-open defaults.",
    [(r'  check_validity "\$bundle" "\$levels_csv" "\$tps_csv"',
      '  VALIDITY=ok; REQ_COUNTS=na; STATUS_FLOOR=ok')],
)

mutation(
    "bench_node_profile_dropped", BENCH,
    "A6: stop passing `--node-profile`, which is what made §4 dead code on the vLLM path while "
    "the two host-process benchers passed it.",
    [(r'\\\n\s*--node-profile "\$NODE_PROFILE" >"\$out"', ' >"$out"')],
    [(r'--node-profile "\$NODE_PROFILE" >"\$out"', '>"$out"')],
)

mutation(
    "bench_fails_open_on_library_error", BENCH,
    "A6: an unreadable verdict defaults to citable and exit 0 — 'a `uv` hiccup produced a fully "
    "citable row'.",
    [(r'\*\) STATUS_FLOOR="void"', '*) STATUS_FLOOR="ok"')],
    [(r'STATUS_FLOOR="void"', 'STATUS_FLOOR="ok"')],
)

mutation(
    "validity_sh_hardcodes_the_header", SHIM,
    "§1: the 23-column header gets a second definition inside the bash shim — the "
    "single-source-of-truth defect this whole body of work existed to remove.",
    [(r'AHL_RESULTS_HEADER="\$\(_ahl_py header\)"',
      'AHL_RESULTS_HEADER="run_id\tcommit\tnode_fp\tmodel\tshape\tbackend\tconfig_hash\t'
      'script\tload_s\tmax_s\tseed\ttps_c1\ttps_c4\ttps_c8\ttps_c16\ttps_c32\tpeak_gb\t'
      'req_counts\tvalidity\tknobs\tstatus\tnotes\tdata"')],
)

mutation(
    "promote_stops_blocking", PROMOTE,
    "§5: `promote.sh` no longer refuses a promotion whose cited row is void/suspect/crash.",
    [(r'if \[ "\$GATE_RC" != 0 \] \|\| \[ "\$GATE_VERDICT" != ok \]; then', "if false; then")],
)

mutation(
    "aggregate_hides_nothing", AGGREGATE,
    "§5: the default view stops holding back void/suspect/crash rows, so a non-citable number "
    "appears in a comparison table as data.",
    [(r"shown_when = \{VOID: include_void, SUSPECT: include_suspect, CRASH: include_crash\}",
      "shown_when = {VOID: True, SUSPECT: True, CRASH: True}")],
)

mutation(
    "suite_maps_exit4_to_ok", SUITE,
    "§5: Gate 3 reports PASS on an invalid measurement.",
    [(r"4\)\s*_v=invalid ;;", "4)  _v=ok ;;")],
)


# ══════════════════════════════════════════════════════════════════════════════════════════════
def apply(name: str, root: Path) -> str:
    """Apply one mutation to `root`. Returns 'applied' or 'not-applicable'."""
    spec = MUTATIONS[name]
    path = root / spec["target"]
    if not path.exists():
        return "not-applicable"
    original = path.read_text()
    for alternate in spec["alternates"]:
        text, ok = original, True
        for pattern, repl in alternate:
            new, n = re.subn(pattern, repl.replace("\\", "\\\\"), text, flags=re.MULTILINE)
            if n == 0:
                ok = False
                break
            text = new
        if ok and text != original:
            path.write_text(text)
            return "applied"
    return "not-applicable"


def main(argv) -> int:
    if not argv or argv[0] == "list":
        for name, spec in MUTATIONS.items():
            print(f"{name}\t{spec['target']}")
        return 0
    if argv[0] == "describe":
        print(MUTATIONS[argv[1]]["why"])
        return 0
    if argv[0] == "apply":
        name, root = argv[1], Path(argv[2])
        if name not in MUTATIONS:
            print(f"unknown mutation: {name}", file=sys.stderr)
            return 2
        print(apply(name, root))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
