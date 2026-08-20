#!/usr/bin/env python3
"""Recover benchmark bundles that no `results.tsv` row references.

    uv run scripts/reconcile_bundles.py                 # DRY RUN — report, change nothing
    uv run scripts/reconcile_bundles.py --write         # append the reconstructed rows
    uv run scripts/reconcile_bundles.py --results /path/to/repo/results   # bundles live there

Why this exists
---------------
`bench.sh` writes its journal row at the END of a shape. Until the trap added in the same commit
as this file, anything that ended the process mid-shape — Ctrl-C, a session limit, `kill`, a
reboot, an OOM that took the script rather than the engine — left `data/<run_id>/` on disk
holding real `level_c*.json` evidence with **no row referencing it**. That evidence is invisible
to `aggregate.py`, to `research/review/AUDIT-measurement-validity.md`, and to every gate: the
committed journal is the record, and the bundles are gitignored.

The trap closes the hole going forward for signals. It cannot close it for `SIGKILL`, a kernel
OOM-kill or a power cut, and it does nothing for the orphans already on disk. This tool is that
half: it walks the results tree, finds the bundles nothing points at, assesses them through
`scripts/lib/validity.py` — the ONLY implementation of the rules (contract §1) — and, with
`--write`, appends one plainly-marked reconstructed row per bundle.

What a reconstructed row may and may not say
--------------------------------------------
A bundle knows its own counts, its tok/s, and the knobs GuideLLM journalled (`max_seconds`,
`random_seed`, the synthetic prompt/output spec, the GuideLLM version). It does NOT know the
repo commit, the runbook or its `config_hash`, the backend image digest, the load time, the peak
memory, or whatever the operator put in `NOTES`. Those are `na` — never a default, never a guess
(contract §4's rule about `mem_bw_gbs`, applied to provenance).

  status   `suspect`, or `void` if the library returns a fatal verdict. NEVER `measured`: that
           means "the invariants passed" on a run somebody actually completed, and nothing here
           can establish that the sweep finished — a bundle whose last level looks complete is
           indistinguishable from one whose process died a second later. NEVER `crash`: that is
           the engine-wedge signal and feeds this node's wedge record. `suspect` is the contract's
           word for "real numbers, not citable until a human records an adjudication", which is
           exactly the state of a row nobody has ever seen.
  notes    says `reconstructed`, names this tool, and lists what could not be recovered, so a
           reader of the journal never has to guess why the provenance columns are `na`.

Safety
------
* DRY RUN by default. `--write` is required to touch a journal, and it only ever APPENDS.
  An existing row is never edited, reordered or deleted.
* A bundle modified within `--min-age` seconds (default 1800) is treated as IN FLIGHT and left
  alone: a bench may be running right now, and its row is not late, it is pending.
* Bundles are read-only evidence. Nothing is written inside one, not even a scratch file.
* `-eval` bundles belong to `accuracy.tsv` and Gate 2 (`scripts/eval_validity.py`), whose rules
  are not these rules. They are reported under their own heading and never reconstructed here.

Exit codes (repo ladder 3 > 4 > 1 > 0): 4 = recoverable orphans found and not yet written;
1 = an error; 0 = nothing to do, or the write succeeded.
"""
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.validity import (  # noqa: E402  — the single source of truth for the rules (§1)
    NA,
    RESULTS_COLS,
    RESULTS_HEADER,
    STATUS_SUSPECT,
    STATUS_VOID,
    assess_bundle,
    format_knobs,
    level_meta,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RESULTS = REPO_ROOT / "results"
DEFAULT_MIN_AGE = 1800          # seconds; a bundle younger than this may still be running

_LEVEL_FILE = re.compile(r"^level_c(\d+)\.json$")
_LEVEL_LOG = re.compile(r"^level_c(\d+)\.log$")
_RUN_ID = re.compile(r"^\d{8}-\d{6}-(?P<shape>[A-Za-z0-9_]+)$")

# The provenance a bundle cannot carry. Named in the row's `notes` so the `na`s are explained
# rather than merely present.
UNRECOVERABLE = ("commit", "config_hash", "script", "backend", "load_s", "peak_gb", "operator notes")


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
class Bundle:
    """One `data/<run_id>/` directory and what the tree says about it."""

    def __init__(self, path: Path, journal: Path, kind: str, reason: str = ""):
        self.path = path
        self.journal = journal          # the results.tsv that WOULD own it
        self.kind = kind                # orphan | referenced | eval | empty | in_flight
        self.reason = reason
        names = [p.name for p in _iterdir(path)]
        self.levels = sorted(int(m.group(1)) for m in
                             (_LEVEL_FILE.match(n) for n in names) if m)
        # A level with a GuideLLM log but no JSON was STARTED and never landed — the fingerprint
        # of a sweep that was cut short. It carries no measurement, so it is never scored; it is
        # reported and written into the row's notes, because "this sweep did not finish" is
        # exactly the fact a reconstructed row would otherwise lose. (The DavidAU orphan on this
        # node looks like a clean two-level sweep until you notice its `level_c32.log`.)
        self.started_only = sorted(
            {int(m.group(1)) for m in (_LEVEL_LOG.match(n) for n in names) if m} - set(self.levels))

    @property
    def run_id(self) -> str:
        return self.path.name

    @property
    def age_s(self) -> float:
        return time.time() - _newest_mtime(self.path)


def _iterdir(path: Path):
    try:
        return sorted(path.iterdir())
    except OSError:
        return []


def _newest_mtime(path: Path) -> float:
    """Newest mtime anywhere in the bundle, including the directory itself. A bench that has
    just finished level 1 has an old directory and a fresh JSON, so the max is what matters."""
    newest = 0.0
    try:
        newest = path.stat().st_mtime
    except OSError:
        return 0.0
    for p in path.rglob("*"):
        try:
            newest = max(newest, p.stat().st_mtime)
        except OSError:
            continue
    return newest


def _referenced(journal: Path) -> set:
    """Bundle directory names any row of `journal` points at — via `data` or via `run_id`.

    Both, deliberately: `data` is the reference, but a row whose `data` cell is `na` (six exist)
    still accounts for its run, and re-reconstructing it would duplicate a published row.

    FAILS CLOSED. A journal that exists but cannot be read raises: swallowing the error would
    return an empty reference set, every published row would look like an orphan, and `--write`
    would duplicate the entire campaign. "A check that degrades into a pass is worse than no
    check" (contract v1.2 A6) applies to a reader as much as to a verdict.
    """
    names: set = set()
    if not journal.exists():
        return names
    with journal.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            for key in ("data", "run_id"):
                val = (row.get(key) or "").strip().rstrip("/")
                if val and val != NA:
                    names.add(val.split("/")[-1])
    return names


def scan(results_dir: Path, min_age: float) -> list:
    """Every bundle under `results_dir`, classified. Read-only."""
    found = []
    for data_dir in sorted(results_dir.glob("*/*/*/data")):
        if not data_dir.is_dir():
            continue
        model_dir = data_dir.parent
        journal = model_dir / "results.tsv"
        try:
            bench_refs = _referenced(journal)
            eval_refs = _referenced(model_dir / "accuracy.tsv")
        except (OSError, UnicodeDecodeError, csv.Error) as exc:
            # Cannot tell an orphan from a published row here, so claim nothing in this model.
            for path in _iterdir(data_dir):
                if path.is_dir():
                    found.append(Bundle(path, journal, "journal_unreadable", str(exc)))
            continue
        for path in _iterdir(data_dir):
            if not path.is_dir():
                continue
            name = path.name
            if name in bench_refs:
                found.append(Bundle(path, journal, "referenced"))
                continue
            m = _RUN_ID.match(name)
            shape = m.group("shape") if m else ""
            if name in eval_refs or shape == "eval":
                # Gate 2's tree. Different journal, different rules (scripts/eval_validity.py).
                kind = "eval" if name in eval_refs else "eval_orphan"
                found.append(Bundle(path, journal, kind))
                continue
            b = Bundle(path, journal, "orphan")
            if b.age_s < min_age:
                b.kind, b.reason = "in_flight", f"modified {b.age_s:.0f}s ago"
            elif not b.levels:
                b.kind, b.reason = "empty", "no level_c<N>.json — no measurement to recover"
            found.append(b)
    return found


# ---------------------------------------------------------------------------
# Reconstruction
# ---------------------------------------------------------------------------
def _fmt_tps(value) -> str:
    """2 dp, matching what bench.sh's `jq '(.*100|round)/100'` puts in the journal."""
    if value is None:
        return NA
    try:
        v = round(float(value), 2)
    except (TypeError, ValueError):
        return NA
    return str(int(v)) if v == int(v) else ("%g" % v)


def _num(value) -> str:
    """A recovered numeric knob, spelled the way the journal spells it. GuideLLM stores
    `max_seconds` as 180.0; bench.sh writes `180`. Same value, and a journal a reader can
    diff against a live row matters more than JSON fidelity."""
    if value is None:
        return NA
    try:
        f = float(value)
    except (TypeError, ValueError):
        return _tsv_safe(value)
    return str(int(f)) if f == int(f) else ("%g" % f)


def _agree(values):
    """The one value every level agrees on, or None. Disagreement is not averaged: a knob that
    changed mid-run is not a knob value, it is two runs in one directory."""
    vals = [v for v in values if v is not None]
    if not vals or any(v != vals[0] for v in vals):
        return None
    return vals[0]


def _meta(bundle: Bundle) -> dict:
    """What GuideLLM journalled inside the bundle, agreed across its levels."""
    per_level = [level_meta(bundle.path / ("level_c%d.json" % lvl)) for lvl in bundle.levels]
    keys = ("max_seconds", "seed", "guidellm_version", "prompt_tokens", "output_tokens")
    return {k: _agree([m.get(k) for m in per_level]) for k in keys}


def _shape_cell(bundle: Bundle, meta: dict) -> str:
    m = _RUN_ID.match(bundle.run_id)
    name = m.group("shape") if m else ""
    prompt, output = meta.get("prompt_tokens"), meta.get("output_tokens")
    if name and prompt is not None and output is not None:
        return "%s(%s/%s)" % (name, prompt, output)
    return name or NA


def _model_cell(model_dir: Path) -> str:
    org, name = model_dir.parent.name, model_dir.name
    return name if org == "_" else "%s/%s" % (org, name)


def reconstruct(bundle: Bundle, results_dir: Path, node_profile: Path | None) -> dict:
    """The results.tsv row a retained bundle can support — and nothing more.

    The verdicts come from `assess_bundle`, with `discover=True` because this IS the
    audit/migration path contract v1.2 A10 carves out: there is no journal row, so there is no
    run-level list to be authoritative, and the files on disk are the only statement of what ran.
    """
    meta = _meta(bundle)
    model_dir = bundle.path.parent.parent
    a = assess_bundle(bundle.path, bundle.levels, None,
                      node_profile=str(node_profile) if node_profile else None,
                      discover=True)
    status = STATUS_VOID if a.status_floor == STATUS_VOID else STATUS_SUSPECT

    tps = {lvl: _fmt_tps(getattr(c, "tps", None)) for lvl, c in a.levels.items()}
    knobs = format_knobs({
        "levels": [str(x) for x in bundle.levels] or NA,
        "max_s": meta.get("max_seconds") if meta.get("max_seconds") is not None else NA,
        "seed": meta.get("seed") if meta.get("seed") is not None else NA,
        "prompt": meta.get("prompt_tokens") if meta.get("prompt_tokens") is not None else NA,
        "output": meta.get("output_tokens") if meta.get("output_tokens") is not None else NA,
        # The bundle records neither guard; a default here would be a fabricated knob set.
        "stall": NA,
        "ltimeout": NA,
        "gllm": meta.get("guidellm_version") or NA,
    })
    today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%d")
    started = ("; level(s) started but left no JSON, so the sweep did not finish: %s"
               % ",".join("c%d" % x for x in bundle.started_only)) if bundle.started_only else ""
    notes = ("RECONSTRUCTED %s by scripts/reconcile_bundles.py from the retained bundle; "
             "no results.tsv row referenced it%s. Not recoverable from a bundle: %s."
             % (today, started, ", ".join(UNRECOVERABLE)))

    row = {c: NA for c in RESULTS_COLS}
    row.update({
        "run_id": bundle.run_id,
        "node_fp": model_dir.parent.parent.name,
        "model": _model_cell(model_dir),
        "shape": _shape_cell(bundle, meta),
        "max_s": _num(meta.get("max_seconds")),
        "seed": _num(meta.get("seed")),
        "tps_c1": tps.get(1, NA), "tps_c4": tps.get(4, NA), "tps_c8": tps.get(8, NA),
        "tps_c16": tps.get(16, NA), "tps_c32": tps.get(32, NA),
        "req_counts": a.req_counts,
        "validity": a.validity,
        "knobs": knobs,
        "status": status,
        "notes": notes,
        "data": _rel(bundle.path, results_dir),
    })
    return row


def _rel(path: Path, results_dir: Path) -> str:
    """Bundle path as the journal records it: relative to the repo root that owns `results/`."""
    try:
        return str(path.resolve().relative_to(results_dir.resolve().parent))
    except ValueError:
        return str(path)


def _tsv_safe(value) -> str:
    """Contract §2: no cell is ever empty, and none carries a tab or a newline."""
    s = str(value if value is not None else "")
    for bad in ("\t", "\n", "\r"):
        s = s.replace(bad, " ")
    return s.strip() or NA


def append_rows(journal: Path, rows: list) -> None:
    """APPEND ONLY. Existing lines are never read back and rewritten — a reconciliation that
    can lose a published row is worse than the gap it closes."""
    want = len(RESULTS_COLS)
    if journal.exists():
        with journal.open(encoding="utf-8") as fh:
            header = (fh.readline() or "").rstrip("\n")
        have = len(header.split("\t")) if header else 0
        if have != want:
            raise SystemExit(
                "%s has a %d-column header; a reconstructed row is %d columns.\n"
                "  migrate it first:  uv run scripts/migrate_results_tsv.py --write"
                % (journal, have, want))
    else:
        journal.parent.mkdir(parents=True, exist_ok=True)
        journal.write_text(RESULTS_HEADER + "\n", encoding="utf-8")
    with journal.open("a", encoding="utf-8") as fh:
        for row in rows:
            fh.write("\t".join(_tsv_safe(row.get(c, NA)) for c in RESULTS_COLS) + "\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _node_profile_for(bundle: Bundle, results_dir: Path) -> Path | None:
    p = results_dir / bundle.path.parent.parent.parent.parent.name / "node_profile.json"
    return p if p.exists() else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="reconcile_bundles",
        description="find and recover benchmark bundles that no results.tsv row references")
    ap.add_argument("--results", default=str(DEFAULT_RESULTS), type=Path,
                    help="results tree to walk (bundles are gitignored: point this at the main "
                         "checkout when running from a worktree)")
    ap.add_argument("--write", action="store_true",
                    help="append the reconstructed rows (default: dry run, change nothing)")
    ap.add_argument("--min-age", type=float, default=DEFAULT_MIN_AGE,
                    help="seconds a bundle must be untouched before it counts as abandoned "
                         "rather than in flight (default %d)" % DEFAULT_MIN_AGE)
    ap.add_argument("--include-empty", action="store_true",
                    help="also write rows for orphan bundles holding no level JSON at all "
                         "(there is no measurement in them; off by default)")
    ap.add_argument("--quiet", action="store_true", help="only the summary and the verdicts")
    args = ap.parse_args(argv)

    results_dir = Path(args.results)
    if not results_dir.is_dir():
        print("no results tree at %s" % results_dir, file=sys.stderr)
        return 1

    bundles = scan(results_dir, args.min_age)
    by_kind: dict = {}
    for b in bundles:
        by_kind.setdefault(b.kind, []).append(b)

    orphans = sorted(by_kind.get("orphan", []), key=lambda b: str(b.path))
    empties = sorted(by_kind.get("empty", []), key=lambda b: str(b.path))
    if args.include_empty:
        orphans = sorted(orphans + empties, key=lambda b: str(b.path))
        empties = []

    print("scanned %d bundle director%s under %s"
          % (len(bundles), "y" if len(bundles) == 1 else "ies", results_dir))
    print("  %4d referenced by a results.tsv row" % len(by_kind.get("referenced", [])))
    print("  %4d Gate-2 eval bundles (accuracy.tsv — out of scope here)"
          % (len(by_kind.get("eval", [])) + len(by_kind.get("eval_orphan", []))))
    print("  %4d in flight (younger than --min-age %ds) — left alone"
          % (len(by_kind.get("in_flight", [])), args.min_age))
    print("  %4d orphan, no level JSON — nothing to recover" % len(empties))
    print("  %4d ORPHAN with retained evidence" % len(orphans))

    unreadable = by_kind.get("journal_unreadable", [])
    if unreadable:
        journals = sorted({str(b.journal) for b in unreadable})
        print("\n!! %d bundle(s) skipped: their journal could not be read, so an orphan cannot be\n"
              "   told apart from a published row. Nothing in these models is claimed:"
              % len(unreadable))
        for j in journals:
            print("     %s" % j)

    eval_orphans = [b for b in by_kind.get("eval_orphan", [])
                    if any(b.path.rglob("results_*.json"))]
    if eval_orphans and not args.quiet:
        print("\nnote: %d unreferenced -eval bundle(s) carry an lm-eval results json — a Gate-2\n"
              "      gap (accuracy.tsv), not this tool's to fix:" % len(eval_orphans))
        for b in eval_orphans:
            print("      %s" % _rel(b.path, results_dir))

    if not orphans:
        print("\nnothing to reconcile.")
        return 1 if unreadable else 0

    rows_by_journal: dict = {}
    for b in orphans:
        row = reconstruct(b, results_dir, _node_profile_for(b, results_dir))
        rows_by_journal.setdefault(b.journal, []).append(row)
        if not args.quiet:
            print("\n%s" % _rel(b.path, results_dir))
            print("    levels   %s%s" % (",".join("c%d" % x for x in b.levels) or "none",
                                         "   started, no JSON: %s"
                                         % ",".join("c%d" % x for x in b.started_only)
                                         if b.started_only else ""))
            print("    counts   %s" % row["req_counts"])
            print("    tps      c1=%s c4=%s c8=%s c16=%s c32=%s"
                  % (row["tps_c1"], row["tps_c4"], row["tps_c8"], row["tps_c16"], row["tps_c32"]))
            print("    validity %s  ->  status=%s" % (row["validity"], row["status"]))
            print("    knobs    %s" % row["knobs"])
            print("    journal  %s" % row["run_id"] + " -> " + str(b.journal))

    if not args.write:
        print("\nDRY RUN — %d row(s) would be appended. Re-run with --write to record them."
              % len(orphans))
        return 4

    for journal, rows in sorted(rows_by_journal.items()):
        append_rows(journal, sorted(rows, key=lambda r: r["run_id"]))
        print("\nappended %d row(s) -> %s" % (len(rows), journal))
    print("\nrecorded %d reconstructed row(s). They are `%s`/`%s`, never `measured`: the "
          "evidence is real, the run's completion is not established."
          % (len(orphans), STATUS_SUSPECT, STATUS_VOID))
    return 1 if unreadable else 0


if __name__ == "__main__":              # pragma: no cover
    sys.exit(main())
