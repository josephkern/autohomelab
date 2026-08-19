#!/usr/bin/env python3
"""Concatenate every results.tsv into one cross-hardware comparison table.

    uv run scripts/aggregate.py [--status keep] [--shape chat] [--csv] [--wide]
                                [--include-void] [--include-suspect] [--validity low_sample]

Every row already carries node_fp / model / shape / backend, so a plain concat yields a
self-describing table comparing the same model across nodes, or configs on one node.
Writes results/aggregate.tsv and prints a compact view.

Validity (docs/validity-contract.md):
  The schema lives in ONE place — `RESULTS_COLS` is imported from scripts/lib/validity.py.
  Both schemas are read: 23-column migrated rows and any 20-column legacy row still around.
  A missing column reads as `na` rather than raising.
  Per contract §5 the default view is *citable data only*: `void` (not data) and `suspect`
  (non-citable) rows are held back, and a one-line summary of what was held back and why is
  always printed to stderr. `--include-void` / `--include-suspect` bring them back, visibly
  marked in the `!` column (`x` = void, `?` = suspect). `--validity <token>` filters on a
  verdict token for auditing and implies both escape hatches, as does an explicit `--status`.
  results/aggregate.tsv is written to match the view exactly — it is never a wider set than
  what was printed, so nothing silently leaks into a downstream consumer of the file.
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.validity import RESULTS_COLS  # noqa: E402  single source of truth for the schema

NA = "na"
# Statuses whose numbers must not appear in a comparison table (contract §5/§6).
VOID = "void"
SUSPECT = "suspect"


def results_root() -> Path:
    """Results tree. `AHL_RESULTS` overrides it (tests point at a fixture tree)."""
    return Path(os.environ.get("AHL_RESULTS") or (REPO_ROOT / "results"))


def normalize(row: dict) -> dict:
    """One row, keyed by the full 23-column schema, with `na` for anything absent.

    csv.DictReader keys by header, so a 20-column legacy row simply lacks the three new
    keys — default them instead of raising. Extra/unknown columns are dropped.
    """
    out = {}
    for col in RESULTS_COLS:
        val = row.get(col)
        out[col] = NA if val is None or str(val).strip() == "" else str(val).strip()
    return out


def load_rows(root: Path | None = None) -> list[dict]:
    """Every results.tsv row under `root`, normalized to the 23-column schema."""
    rows: list[dict] = []
    for tsv in sorted((root or results_root()).glob("*/*/*/results.tsv")):
        with tsv.open(newline="") as f:
            for r in csv.DictReader(f, delimiter="\t", restval=NA, restkey="_extra"):
                rows.append(normalize(r))
    return rows


def citability(row: dict) -> str:
    """`ok` | `suspect` | `void` — whether this row's numbers may be cited.

    Contract §5 downgrades `status` to void/suspect, so status is the primary signal. The
    one exception the contract leaves open is a `crash` row: it *keeps* status=crash and
    records its verdict in `validity`, so a crashed run carrying a fatal verdict (the
    449,358 tok/s case) would otherwise sail through a status-only filter. Any row with a
    recorded verdict other than `ok` is therefore treated as at least suspect. This needs
    no severity table, so it cannot drift out of sync with the library.
    """
    status = row.get("status", NA)
    if status == VOID:
        return VOID
    if status == SUSPECT:
        return SUSPECT
    verdict = row.get("validity", NA)
    if verdict not in (NA, "ok"):
        return SUSPECT
    return "ok"


def verdict_tokens(row: dict) -> list[str]:
    """The `+`-joined verdict tokens of a row (empty for `ok`/`na`)."""
    verdict = row.get("validity", NA)
    if verdict in (NA, "ok"):
        return []
    return [t for t in verdict.split("+") if t]


def min_ok(row: dict) -> str:
    """Smallest `successful` count across the run levels, `!` if a level looks unhealthy.

    `req_counts` is `c1:41/0/0;c16:118/4/0` (ok/incomplete/errored per run level). The
    minimum is the number that decides whether the curve is judgeable at all — a c32
    figure computed from 2 requests is exactly what this column exists to expose. A few
    `incomplete` per level is normal (requests still in flight when the stage ends), so
    `!` is reserved for a level with any `errored`, or with more incomplete than complete
    (a starved stage).
    """
    raw = row.get("req_counts", NA)
    if raw in (NA, ""):
        return NA
    oks, sick = [], False
    for part in raw.split(";"):
        _, _, counts = part.partition(":")
        fields = counts.split("/")
        if len(fields) != 3 or not all(f.isdigit() for f in fields):
            return NA
        ok, incomplete, errored = (int(f) for f in fields)
        oks.append(ok)
        sick = sick or errored > 0 or incomplete > ok
    if not oks:
        return NA
    return f"{min(oks)}{'!' if sick else ''}"


def clip(text: str, width: int) -> str:
    return text if len(text) <= width else text[: width - 1] + "…"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", help="filter by status (e.g. keep, void, suspect, crash); "
                                     "naming a status implies the include-* escape hatches")
    ap.add_argument("--shape", help="filter by shape prefix (e.g. chat)")
    ap.add_argument("--csv", action="store_true", help="print comma-separated instead of aligned")
    ap.add_argument("--wide", action="store_true",
                    help="show the full validity + req_counts strings instead of the compact form")
    ap.add_argument("--include-void", action="store_true",
                    help="also show status=void rows (contract: not data, must not be cited)")
    ap.add_argument("--include-suspect", action="store_true",
                    help="also show status=suspect rows (measured, but invariants question them)")
    ap.add_argument("--validity", metavar="TOKEN",
                    help="only rows whose validity carries TOKEN (e.g. low_sample); "
                         "implies --include-void --include-suspect")
    args = ap.parse_args()

    # An explicit --status/--validity names the population being audited, so it implies the
    # escape hatches (rows are still marked in the `!` column and counted on stderr).
    named = bool(args.status) or bool(args.validity)
    include_void = args.include_void or named
    include_suspect = args.include_suspect or named

    rows = load_rows()
    total = len(rows)

    if args.status:
        rows = [r for r in rows if r["status"] == args.status]
    if args.shape:
        rows = [r for r in rows if r["shape"].startswith(args.shape)]
    if args.validity:
        rows = [r for r in rows if args.validity in verdict_tokens(r)]

    # Validity filter — the point of the default view: a non-citable number never appears
    # silently in a comparison table.
    kept, hidden = [], []
    for r in rows:
        cite = citability(r)
        if cite == VOID and not include_void:
            hidden.append((r, cite))
        elif cite == SUSPECT and not include_suspect:
            hidden.append((r, cite))
        else:
            kept.append(r)
    rows = kept

    n_void = sum(1 for _, c in hidden if c == VOID)
    n_suspect = len(hidden) - n_void
    why = Counter(t for r, _ in hidden for t in verdict_tokens(r))
    reasons = ", ".join(f"{t}x{n}" for t, n in sorted(why.items())) or "no verdict tokens"
    summary = (f"validity: {total} rows read, {len(rows)} shown, {len(hidden)} held back "
               f"({n_void} void, {n_suspect} suspect; {reasons})"
               + ("" if not hidden else " -- --include-void/--include-suspect to show"))
    print(summary, file=sys.stderr)

    if not rows:
        sys.exit("no matching result rows found"
                 + (f" ({len(hidden)} held back by the validity filter)" if hidden else ""))

    rows.sort(key=lambda r: (r["node_fp"], r["model"], r["shape"], r["run_id"]))

    out = results_root() / "aggregate.tsv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=RESULTS_COLS, delimiter="\t", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    # Console view: a marker, identity, the validity signals, then the tok/s curve.
    # Compact by default so it fits a terminal; --wide (or --csv, which feeds a machine)
    # gives the untruncated strings and the full per-level req_counts.
    compact = not (args.wide or args.csv)
    view = ["!", "node_fp", "model", "shape", "config_hash", "status", "validity",
            "min_ok" if compact else "req_counts",
            "tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32"]
    mark = {VOID: "x", SUSPECT: "?", "ok": " "}
    table = [view]
    for r in rows:
        cells = dict(r)
        cells["!"] = mark[citability(r)]
        cells["min_ok"] = min_ok(r)
        if compact:
            # keep the table inside a terminal: the long GGUF model names run to 79 chars
            cells["model"] = clip(r["model"], 40)
            cells["validity"] = clip(r["validity"], 18)
        table.append([cells.get(c, NA) for c in view])

    if args.csv:
        for line in table:
            print(",".join(line))
    else:
        widths = [max(len(str(row[i])) for row in table) for i in range(len(view))]
        for row in table:
            print("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(row)))
    legend = "! x=void ?=suspect" + ("" if not compact else
                                     " | min_ok = fewest successful requests of any run level"
                                     " (! = a level errored or starved); --wide for req_counts")
    print(f"\n{legend}", file=sys.stderr)
    try:
        shown = out.relative_to(REPO_ROOT)
    except ValueError:
        shown = out
    print(f"wrote {shown} ({len(rows)} rows)", file=sys.stderr)


if __name__ == "__main__":
    main()
