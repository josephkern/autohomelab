#!/usr/bin/env python3
"""Leaderboard for the tuning loop: median tok/s per config, ranked, current best marked.

    uv run scripts/tune_status.py [--model RedHatAI/Qwen3-8B-NVFP4] [--shape chat] [--node <fp>]

Groups results.tsv rows by (config_hash, shape), takes the median c16 (objective) + c1 across that
config's benches, ranks by median c16 desc, and marks the leader ★. This is how keep/discard is
decided: a candidate is a "keep" only if its median c16 beats the current best beyond noise.
"""
from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--shape", default="chat")
    ap.add_argument("--node")
    args = ap.parse_args()

    rows = []
    for tsv in sorted((REPO_ROOT / "results").glob("*/*/*/results.tsv")):
        rows += list(csv.DictReader(tsv.open(), delimiter="\t"))

    groups = defaultdict(lambda: {"c1": [], "c16": [], "c32": [], "script": "", "crash": 0, "n": 0})
    for r in rows:
        if args.model and r["model"] != args.model:
            continue
        if args.node and r["node_fp"] != args.node:
            continue
        if not r.get("shape", "").startswith(args.shape):
            continue
        g = groups[(r["config_hash"], r["shape"])]
        g["script"] = r["script"]
        if r.get("status") == "crash":
            g["crash"] += 1
        for col in ("c1", "c16", "c32"):
            try:
                g[col].append(float(r[f"tps_{col}"]))
            except (ValueError, TypeError, KeyError):
                pass
        g["n"] += 1

    if not groups:
        print("no matching rows")
        return

    table = []
    for (cfg, shape), g in groups.items():
        table.append((med(g["c16"]) or -1, cfg, shape, med(g["c1"]), med(g["c16"]),
                      med(g["c32"]), g["n"], g["crash"], g["script"]))
    table.sort(reverse=True)

    print(f"{'':2}{'config':9} {'shape':16} {'c1':>7} {'c16*':>7} {'c32':>7} {'n':>3} {'crash':>5}  script")
    for i, (_, cfg, shape, c1, c16, c32, n, crash, script) in enumerate(table):
        star = "★" if i == 0 and c16 is not None else " "
        print(f"{star} {cfg:9} {shape:16} {str(c1):>7} {str(c16):>7} {str(c32):>7} {n:>3} {crash:>5}  {script}")
    print("\n★ = current best by median c16 (the tuning objective).")


if __name__ == "__main__":
    main()
