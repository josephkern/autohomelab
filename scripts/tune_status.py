#!/usr/bin/env python3
"""Leaderboard for the tuning loop: median tok/s per config, ranked, current best marked.

    uv run scripts/tune_status.py [--model RedHatAI/Qwen3-8B-NVFP4] [--shape chat] [--node <fp>]
                                  [--include-void] [--include-suspect]

Groups results.tsv rows by (config_hash, shape), takes the median c16 (objective) + c1 across that
config's benches, ranks by median c16 desc, and marks the leader ★. This is how keep/discard is
decided: a candidate is a "keep" only if its median c16 beats the current best beyond noise.

Validity (docs/validity-contract.md §5): a median must never be taken over `void` or `suspect`
rows. They are excluded from every median here and counted in the `void`/`susp` columns instead,
so a config whose benches were all thrown out still shows up — with n=0 — rather than vanishing.
`--include-void` / `--include-suspect` fold them back in and mark the row `!`. Rows are read via
aggregate.py, which owns the schema-tolerant reader (23-column and 20-column legacy alike).
"""
from __future__ import annotations

import argparse
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from aggregate import citability, load_rows, verdict_tokens  # noqa: E402


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--shape", default="chat")
    ap.add_argument("--node")
    ap.add_argument("--include-void", action="store_true",
                    help="include status=void rows in the medians (contract: not data)")
    ap.add_argument("--include-suspect", action="store_true",
                    help="include status=suspect rows in the medians (contract: non-citable)")
    args = ap.parse_args()

    rows = load_rows()

    groups = defaultdict(lambda: {"c1": [], "c16": [], "c32": [], "script": "",
                                  "crash": 0, "void": 0, "susp": 0, "n": 0})
    hidden = flagged = 0
    why: Counter = Counter()
    for r in rows:
        if args.model and r["model"] != args.model:
            continue
        if args.node and r["node_fp"] != args.node:
            continue
        if not r["shape"].startswith(args.shape):
            continue
        g = groups[(r["config_hash"], r["shape"], r.get("max_s", "na"))]
        g["script"] = r["script"]
        if r["status"] == "crash":
            g["crash"] += 1

        cite = citability(r)
        if cite != "ok":
            g[{"void": "void", "suspect": "susp"}[cite]] += 1
            flagged += 1
            why.update(verdict_tokens(r))
            if not (args.include_void if cite == "void" else args.include_suspect):
                hidden += 1
                continue  # never let a non-citable number into a median

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
    for (cfg, shape, max_s), g in groups.items():
        table.append((med(g["c16"]) or -1, cfg, shape, max_s, med(g["c1"]), med(g["c16"]),
                      med(g["c32"]), g["n"], g["crash"], g["void"], g["susp"], g["script"]))
    table.sort(reverse=True)

    print(f"{'':2}{'config':9} {'shape':16} {'max_s':>5} {'c1':>7} {'c16*':>7} {'c32':>7} "
          f"{'n':>3} {'crash':>5} {'void':>4} {'susp':>4}  script")
    folded = args.include_void or args.include_suspect
    for i, (_, cfg, shape, max_s, c1, c16, c32, n, crash, void, susp, script) in enumerate(table):
        star = "★" if i == 0 and c16 is not None else " "
        flag = "!" if folded and (void or susp) else " "
        print(f"{star}{flag}{cfg:9} {shape:16} {str(max_s):>5} {str(c1):>7} {str(c16):>7} "
              f"{str(c32):>7} {n:>3} {crash:>5} {void:>4} {susp:>4}  {script}")
    print("\n★ = current best by median c16 (the tuning objective). "
          "n = benches contributing to the medians"
          + (" (void/suspect FOLDED IN, rows marked !)." if folded else "; void/susp are excluded."))
    reasons = ", ".join(f"{t}x{n}" for t, n in sorted(why.items())) or "none"
    print(f"validity: {flagged} flagged row(s) [{reasons}], {hidden} excluded from the medians"
          + ("." if folded else "; --include-void/--include-suspect to fold them in."),
          file=sys.stderr)


if __name__ == "__main__":
    main()
