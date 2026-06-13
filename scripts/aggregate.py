#!/usr/bin/env python3
"""Concatenate every results.tsv into one cross-hardware comparison table.

    uv run scripts/aggregate.py [--status keep] [--shape chat] [--csv]

Every row already carries node_fp / model / shape / backend, so a plain concat yields a
self-describing table comparing the same model across nodes, or configs on one node.
Writes results/aggregate.tsv and prints a compact view.
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RESULTS = REPO_ROOT / "results"
COLS = ["run_id", "commit", "node_fp", "model", "shape", "backend", "config_hash", "script",
        "load_s", "max_s", "seed", "tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32", "peak_gb",
        "status", "notes", "data"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", help="filter by status (e.g. keep)")
    ap.add_argument("--shape", help="filter by shape prefix (e.g. chat)")
    ap.add_argument("--csv", action="store_true", help="print comma-separated instead of aligned")
    args = ap.parse_args()

    rows: list[dict] = []
    for tsv in sorted(RESULTS.glob("*/*/*/results.tsv")):
        with tsv.open() as f:
            for r in csv.DictReader(f, delimiter="\t"):
                rows.append(r)

    if args.status:
        rows = [r for r in rows if r.get("status") == args.status]
    if args.shape:
        rows = [r for r in rows if r.get("shape", "").startswith(args.shape)]
    if not rows:
        sys.exit("no matching result rows found")

    rows.sort(key=lambda r: (r["node_fp"], r["model"], r["shape"], r["run_id"]))

    out = RESULTS / "aggregate.tsv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, delimiter="\t", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    # Compact console view: identity + the tok/s curve.
    view = ["node_fp", "model", "shape", "config_hash", "status",
            "tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32"]
    table = [view] + [[r.get(c, "") for c in view] for r in rows]
    if args.csv:
        for line in table:
            print(",".join(line))
    else:
        widths = [max(len(str(row[i])) for row in table) for i in range(len(view))]
        for row in table:
            print("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(row)))
    print(f"\nwrote {out.relative_to(REPO_ROOT)} ({len(rows)} rows)", file=sys.stderr)


if __name__ == "__main__":
    main()
