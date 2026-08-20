#!/usr/bin/env python3
"""Migrate `accuracy.tsv` from 12 columns to 16 (docs/validity-contract.md A9).

    uv run scripts/migrate_accuracy_tsv.py --check          # report, change nothing
    uv run scripts/migrate_accuracy_tsv.py --write          # migrate in place
    uv run scripts/migrate_accuracy_tsv.py --write --tsv results/<fp>/<org>/<model>/accuracy.tsv

Adds, appended AFTER `think` so the positional readers stay valid (validate.sh reads `$5`
config_hash and `$10` scores):

    conc      the concurrency the eval ran at. AGENTS.md carries an open follow-up saying every
              accuracy row is "a single unrecorded point at c16" because `eval.sh` sets
              `CONC=16` and nothing ever overrode it. The column is added so that stops being
              true. **The bundles disagree with the follow-up**: two ds4 rows really ran at
              `num_concurrent=4`, so this backfills from each bundle's own
              `config.model_args.num_concurrent` — evidence, not the assumption. A row with no
              bundle gets `na`; it is not guessed.
    samples   `task=effective/requested` per requested task, `;`-joined. The evidence for the
              completeness check, so a later reader can re-derive the verdict under a different
              threshold.
    validity  the Gate-2 verdict tokens (scripts/eval_validity.py), `+`-joined, `ok` when clean.
    status    contract §6, floored by the verdict: `measured` / `suspect` / `void`.

`scores` is NEVER rewritten — the historical text is the record. The migration recomputes it from
the bundle and reports any divergence instead (all 76 committed rows reproduce byte-exact).
Idempotent: a file already carrying the new header is left alone.

Bundles are gitignored and absent from agent worktrees — pass `--bundle-root` pointing at the main
checkout when running from one (contract §7).
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from eval_validity import NA, assess  # noqa: E402

# Schema comes from eval_validity.py — one definition (see its ACCURACY_* block).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from eval_validity import (  # noqa: E402
    ACCURACY_LEGACY_COLS as LEGACY_HEADER,
    ACCURACY_NEW_COLS as NEW_COLS,
    ACCURACY_COLS as HEADER,
)


def migrate_file(path: Path, bundle_root: Path, write: bool) -> dict:
    stat = {"path": str(path), "rows": 0, "already": False, "no_bundle": 0,
            "score_divergence": [], "verdicts": {}, "conc": {}}
    with open(path, newline="") as f:
        rows = list(csv.reader(f, delimiter="\t"))
    if not rows:
        stat["already"] = True
        return stat
    header = rows[0]
    if header == HEADER:
        stat["already"] = True
        return stat
    if header != LEGACY_HEADER:
        raise SystemExit("%s: unrecognized header %r — refusing to guess" % (path, header))

    out = [HEADER]
    for raw in rows[1:]:
        if not raw:
            continue
        stat["rows"] += 1
        row = dict(zip(LEGACY_HEADER, raw))
        bundle = bundle_root / row.get("data", "")
        if not row.get("data") or row.get("data") == NA or not bundle.exists():
            stat["no_bundle"] += 1
            new = {"conc": NA, "samples": NA, "validity": NA, "status": NA}
        else:
            a = assess(str(bundle), row.get("tasks", ""))
            if a["scores"] != NA and a["scores"] != ";".join(sorted(row["scores"].split(";"))):
                stat["score_divergence"].append((row["run_id"], row["scores"], a["scores"]))
            new = {"conc": a["conc"], "samples": a["samples"],
                   "validity": a["validity"], "status": a["status"]}
        stat["verdicts"][new["validity"]] = stat["verdicts"].get(new["validity"], 0) + 1
        stat["conc"][new["conc"]] = stat["conc"].get(new["conc"], 0) + 1
        out.append([row[c] for c in LEGACY_HEADER] + [new[c] for c in NEW_COLS])

    if write:
        tmp = path.with_suffix(".tsv.tmp")
        with open(tmp, "w", newline="") as f:
            csv.writer(f, delimiter="\t", lineterminator="\n").writerows(out)
        # Round-trip check BEFORE replacing: every legacy cell must survive byte-identical.
        with open(tmp, newline="") as f:
            back = list(csv.reader(f, delimiter="\t"))
        assert back[0] == HEADER, "header not written"
        assert len(back) == len(rows), "row count changed %d -> %d" % (len(rows), len(back))
        for old, got in zip(rows[1:], back[1:]):
            assert got[:len(LEGACY_HEADER)] == old, "legacy cells changed: %r -> %r" % (old, got)
        os.replace(tmp, path)
    return stat


def main(argv=None) -> int:
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tsv", action="append", default=[], help="migrate just this file")
    ap.add_argument("--root", default=str(repo / "results"), help="tree to scan for accuracy.tsv")
    ap.add_argument("--bundle-root", default=str(repo),
                    help="checkout whose results/**/data holds the bundles (contract §7)")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true", help="report only (the default)")
    args = ap.parse_args(argv)

    files = [Path(p) for p in args.tsv] or sorted(Path(args.root).glob("*/*/*/accuracy.tsv"))
    if not files:
        print("no accuracy.tsv under %s" % args.root)
        return 0
    write = args.write and not args.check
    totals = {"rows": 0, "no_bundle": 0, "files": 0, "already": 0}
    verdicts, concs, diverged = {}, {}, []
    for p in files:
        s = migrate_file(p, Path(args.bundle_root), write)
        if s["already"]:
            totals["already"] += 1
            continue
        totals["files"] += 1
        totals["rows"] += s["rows"]
        totals["no_bundle"] += s["no_bundle"]
        diverged += s["score_divergence"]
        for k, v in s["verdicts"].items():
            verdicts[k] = verdicts.get(k, 0) + v
        for k, v in s["conc"].items():
            concs[k] = concs.get(k, 0) + v
        print("%-6s %s (%d rows)" % ("WROTE" if write else "would", p, s["rows"]))
    print("\n%s: %d file(s), %d row(s); %d already migrated; %d row(s) with no bundle"
          % ("migrated" if write else "dry run", totals["files"], totals["rows"],
             totals["already"], totals["no_bundle"]))
    print("conc backfill: " + ", ".join("%s=%d" % kv for kv in sorted(concs.items())))
    print("validity:      " + ", ".join("%s=%d" % kv for kv in sorted(verdicts.items())))
    if diverged:
        print("SCORE DIVERGENCE (recorded text kept; recomputation differs):")
        for rid, old, new in diverged:
            print("  %s  recorded=%s  recomputed=%s" % (rid, old, new))
    return 0


if __name__ == "__main__":
    sys.exit(main())
