#!/usr/bin/env python3
"""Mutation harness for the GATE 2 validity layer (docs/validity-contract.md A8).

    uv run scripts/eval_validity_mutations.py          # or: python3 scripts/...

"A rule with no mutation that turns the suite red is an untested rule." A8 was written because
mutation testing found 16 surviving mutations in the Gate-3 layer: every v1.1 amendment and every
enforcement path could be deleted with 121/121 green. This runs the same check against Gate 2.

Each entry disables one rule or one piece of enforcement, runs
`scripts/eval_validity_selftest.sh`, and restores the file. A mutation that leaves the suite green
is reported as SURVIVING and the harness exits 1 — that mutation names a rule nothing checks.

Touches only the working tree, and only for the duration of one run; it restores the original
bytes even when the suite crashes. No docker, no GPU, no network.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUITE = REPO / "scripts" / "eval_validity_selftest.sh"

#: (label, file, find, replace) — `find` must appear EXACTLY once or the mutation is reported
#: as un-anchored rather than silently skipped.
MUTATIONS = [
    ("predicate: drop the non-finite check", "scripts/eval_validity.py",
     "        elif not math.isfinite(float(value)):", "        elif False:"),
    ("predicate: drop the sample-count check", "scripts/eval_validity.py",
     "        if req > 0 and eff < MIN_SAMPLE_FRAC * req:", "        if False:"),
    ("predicate: no results json becomes a pass", "scripts/eval_validity.py",
     '        res["validity"] = format_validity([V_NO_SCORE])\n'
     '        res["status"] = apply_status(status, status_floor([V_NO_SCORE]))\n'
     '        res["reasons"].append("no results_*.json under %s — lm-eval produced no score" % bundle)\n'
     '        return res',
     '        res["validity"] = "ok"\n        res["status"] = "measured"\n'
     '        res["citable"] = True\n        return res'),
    ("predicate: zero score becomes clean", "scripts/eval_validity.py",
     "        elif float(value) == 0.0:", "        elif False:"),
    ("predicate: fail-OPEN when n-samples is missing", "scripts/eval_validity.py",
     "            verds.append(tag_verdict(V_NO_SAMPLES, task))", "            pass"),
    ("eval.sh: stop exiting 4 on a non-citable row", "scripts/eval.sh",
     '[ "${EV_CITABLE:-0}" = 1 ] || rc=4', "true"),
    ("eval.sh: stop writing the new columns", "scripts/eval.sh",
     '"${EV_CONC:-$CONC}" "$SAMPLES" "$VALIDITY" \\\n  "$EV_STATUS" >> "$TSV"',
     '"na" "na" "na" "na" >> "$TSV"'),
    ("suite.sh: Gate-2 exit 4 stops latching", "scripts/suite.sh",
     'for _g2 in "$gen" "$res" "$bench"; do', 'for _g2 in "$bench"; do'),
    ("suite.sh: reasoning x spec falls back into the reasoning branch", "scripts/suite.sh",
     'if [ "$REASONING" = 1 ] && [ "$SPEC" = 1 ]; then', "if false; then"),
    ("suite.sh: spec-decode branch removed", "scripts/suite.sh",
     'elif [ "$SPEC" = 1 ]; then', "elif false; then"),
    ("migration: guess conc=16 instead of reading the bundle", "scripts/migrate_accuracy_tsv.py",
     '            new = {"conc": a["conc"],', '            new = {"conc": "16",'),
    ("migration: stop preserving legacy cells", "scripts/migrate_accuracy_tsv.py",
     "        out.append([row[c] for c in LEGACY_HEADER] + [new[c] for c in NEW_COLS])",
     '        out.append(["x" for c in LEGACY_HEADER] + [new[c] for c in NEW_COLS])'),
]


def run_suite() -> tuple:
    r = subprocess.run(["bash", str(SUITE)], capture_output=True, text=True, cwd=str(REPO),
                       env={**os.environ, "AHL_SHOW_TRACE": "0"})
    line = [l for l in r.stdout.splitlines() if "GATE 2 SELFTEST" in l]
    return r.returncode, (line[-1] if line else "(suite produced no summary)")


def main() -> int:
    rc, summary = run_suite()
    print("baseline: %s" % summary)
    if rc != 0:
        print("the suite is RED before any mutation - fix that first")
        return 1

    survived = []
    for label, rel, find, repl in MUTATIONS:
        path = REPO / rel
        original = path.read_text()
        n = original.count(find)
        if n != 1:
            print("%-5s %-62s anchor matched %d times" % ("??", label, n))
            survived.append(label + "  [anchor no longer matches - the mutation is not testing anything]")
            continue
        path.write_text(original.replace(find, repl))
        try:
            rc, summary = run_suite()
        finally:
            path.write_text(original)
        print("%-5s %-62s %s" % ("KILL" if rc else "LIVE", label, summary))
        if rc == 0:
            survived.append(label)

    print("\nsurviving mutations: %d of %d" % (len(survived), len(MUTATIONS)))
    for s in survived:
        print("  " + s)
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
