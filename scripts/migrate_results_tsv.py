#!/usr/bin/env python3
"""Migrate every ``results/*/*/*/results.tsv`` from the legacy 20-column schema to
the 23 columns of ``docs/validity-contract.md`` §2, backfilling the three new
columns from retained GuideLLM bundles.

    run_id commit node_fp model shape backend config_hash script
    load_s max_s seed tps_c1 tps_c4 tps_c8 tps_c16 tps_c32 peak_gb
    req_counts validity knobs            <-- inserted here
    status notes data

Design notes
------------
* **Dry-run is the default.** ``--apply`` is required to touch a file.
* **Idempotent.** A file already carrying ``RESULTS_HEADER`` is reported and left
  alone. ``--recompute`` re-derives the three columns on an already-migrated file
  (useful once ``node_profile.json`` gains ``gpu.mem_bw_gbs`` and the §4 roofline
  check stops being skipped); it never touches the other 20 columns.
* **Rules live in one place.** Every threshold, verdict and formatting rule is
  imported from ``scripts/lib/validity.py``; this script contains none of them.
* **status is never modified** (contract §7 — the orchestrator adjudicates those
  row by row). We compute and record the verdict; we do not act on it.
* Bundles under ``results/**/data/`` are gitignored and therefore absent from a
  worktree. ``--bundle-root`` points at the checkout that has them; the script
  only ever *reads* from there.

Backfill provenance
-------------------
``req_counts`` / ``validity`` come from the bundle only. No bundle -> both ``na``.
An unaudited row must never render as a passing one, so ``validity=na`` (never
``ok``) when there is nothing to audit.

``knobs`` is reconstructed from whatever the row itself proves, bundle or not:

===========  ==========================================================
 levels       levels with a non-``na`` tps column, unioned with levels
              that have a ``level_c<N>.json``  (provable)
 max_s        the ``max_s`` column, else the bundle's ``args.max_seconds``
 seed         the ``seed`` column, else the bundle's ``args.random_seed``
 prompt       parsed from the ``shape`` column ``chat(512/256)``
 output       likewise
 gllm         the bundle's ``metadata.guidellm_version``
 stall        never recorded historically -> ``na``
 ltimeout     never recorded historically -> ``na``
===========  ==========================================================

Run levels
----------
A level counts as RUN if it has a tps value **or** a ``level_c<N>.json`` on disk.
The union matters: nine ``status=crash`` rows disagree between the two (a tps was
journalled for a level whose json never landed, or a json landed for a level whose
tps was dropped). Taking the union means such a level is audited rather than
silently skipped, and a run level with no parseable json trips ``no_data`` — which
is the honest verdict for a number we cannot check. Levels that are ``na`` in the
tps columns *and* absent from the bundle are unrun and are skipped entirely, never
treated as zero (contract §3).

ASSUMED API of scripts/lib/validity.py (agent A1 owns that file; if the real
signatures differ, the fixes are confined to :func:`_row_verdict` and the two
format calls in :func:`migrate_row`):

    RESULTS_COLS, LEGACY_COLS, RESULTS_HEADER, LEGACY_HEADER, LEVELS, NA
    parse_level_json(path) -> dict | None
        dict keys used here: successful, incomplete, errored, tps, max_seconds,
        seed, prompt_tokens, output_tokens, guidellm_version
    verdicts(levels: dict[int, dict|None], ceiling_fn=None) -> list[str]
    format_req_counts(levels: dict[int, dict|None]) -> str
    format_knobs(dict) -> str
    roofline_ceiling(level, mem_bw_gbs, bytes_per_token_gb=None) -> float | None
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_LIB = REPO / "scripts" / "lib"
if _LIB.is_dir():
    sys.path.insert(0, str(_LIB))

try:
    import validity as V  # noqa: E402
except ImportError as exc:  # pragma: no cover
    sys.exit(
        "cannot import scripts/lib/validity.py (%s).\n"
        "It is the single source of truth for the rules; this script "
        "deliberately does not re-implement them." % exc
    )

# Reporting order for the knob fill-rate table. The library takes knobs as kwargs and
# preserves their order, so this is a local presentation concern, not part of the schema.
KNOB_ORDER = ("levels", "max_s", "seed", "prompt", "output", "stall", "ltimeout", "gllm")

SHAPE_RE = re.compile(r"\((\d+)\s*/\s*(\d+)\)")


# --------------------------------------------------------------------------
# node profile / roofline
# --------------------------------------------------------------------------

def load_mem_bw(repo: Path, node_fp: str, cache={}):
    """gpu.mem_bw_gbs for a node, or None -> §4 check is skipped.

    Never invents a bandwidth number.
    """
    if node_fp in cache:
        return cache[node_fp]
    val = None
    prof = repo / "results" / node_fp / "node_profile.json"
    try:
        with prof.open() as fh:
            doc = json.load(fh)
        raw = (doc.get("gpu") or {}).get("mem_bw_gbs")
        if isinstance(raw, (int, float)) and raw > 0:
            val = float(raw)
    except (OSError, ValueError):
        val = None
    cache[node_fp] = val
    return val


# --------------------------------------------------------------------------
# per-row work
# --------------------------------------------------------------------------

def _tps_levels(cols):
    """Levels whose tps column carries a value."""
    base = V.LEGACY_COLS.index("tps_c1")
    return {lvl for i, lvl in enumerate(V.LEVEL_COLUMNS) if cols[base + i] != V.NA}


def _bundle_levels(bundle_dir: Path):
    if bundle_dir is None or not bundle_dir.is_dir():
        return set()
    out = set()
    for p in bundle_dir.iterdir():
        m = re.fullmatch(r"level_c(\d+)\.json", p.name)
        if m:
            out.add(int(m.group(1)))
    return out


def _row_verdict(levels, mem_bw):
    if not levels:
        return [V.NA]
    ceiling_fn = None
    if mem_bw is not None:
        # bytes_per_token is unknown for historical rows -> the library's
        # AHL_MIN_MODEL_GB fallback yields the loose-but-sound bound of §4.
        ceiling_fn = lambda lvl: V.ceiling(lvl, mem_bw)  # noqa: E731
    return V.verdicts(levels, ceiling_fn=ceiling_fn)


def migrate_row(cols, bundle_root: Path, repo: Path, stats: Counter):
    """Return the 23 new field values for one legacy 20-field row."""
    get = lambda name: cols[V.LEGACY_COLS.index(name)]  # noqa: E731

    data = get("data")
    bundle = None if data == V.NA else (bundle_root / data)

    tlv = _tps_levels(cols)
    blv = _bundle_levels(bundle)
    run = sorted(tlv | blv)

    parsed = OrderedDict()
    metas = OrderedDict()
    for lvl in run:
        path = None if bundle is None else bundle / ("level_c%d.json" % lvl)
        if path is None:
            parsed[lvl] = None
            continue
        try:
            parsed[lvl] = V.parse_level_json(str(path))
        except V.LevelParseError:
            # Level was run (journal cell or sibling bundle file) but its json is gone or
            # corrupt: the contract's `no_data`, recorded as `c<N>:na` rather than a zero.
            parsed[lvl] = V.LevelCounts(missing=True)
        meta = V.level_meta(str(path))
        if meta:
            metas[lvl] = meta

    have_bundle = any(d is not None for d in parsed.values())
    if have_bundle:
        req_counts = V.format_req_counts(parsed)
        vtoks = _row_verdict(parsed, load_mem_bw(repo, get("node_fp"), ))
        stats["backfill_real"] += 1
    else:
        # Nothing retained to audit: `na`, never `ok`.
        req_counts = V.NA
        vtoks = [V.NA]
        stats["backfill_na"] += 1
    validity = "+".join(vtoks)
    stats["verdict:" + validity] += 1
    stats["severity:" + V.status_floor(vtoks)] += 1

    # ---- knobs -----------------------------------------------------------
    first = next(iter(metas.values()), None)

    def col_or_bundle(colname, key):
        v = get(colname)
        if v and v != V.NA:
            return _tidy_num(v)
        if first is not None and first.get(key) is not None:
            return _tidy_num(first[key])
        return None

    prompt = output = None
    m = SHAPE_RE.search(get("shape"))
    if m:
        prompt, output = m.group(1), m.group(2)
    elif first is not None:
        prompt, output = first.get("prompt_tokens"), first.get("output_tokens")

    knobs = {
        "levels": sorted(run) if run else None,
        "max_s": col_or_bundle("max_s", "max_seconds"),
        "seed": col_or_bundle("seed", "seed"),
        "prompt": prompt,
        "output": output,
        "stall": None,      # STALL_SECS was never journalled
        "ltimeout": None,   # per-level timeout was never journalled
        "gllm": first.get("guidellm_version") if first else None,
    }
    for k, v in knobs.items():
        if v is not None:
            stats["knob:" + k] += 1
    knobs_s = V.format_knobs(**knobs)

    idx = V.LEGACY_COLS.index("peak_gb")
    return cols[: idx + 1] + [req_counts, validity, knobs_s] + cols[idx + 1:]


def _tidy_num(v):
    """180.0 -> 180, so knobs read like the contract's example."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return str(v)
    return str(int(f)) if f == int(f) else str(f)


# --------------------------------------------------------------------------
# per-file work
# --------------------------------------------------------------------------

class FileResult:
    def __init__(self, path):
        self.path = path
        self.state = "pending"
        self.rows = 0
        self.stats = Counter()
        self.text = None
        self.changed = False


def migrate_file(path: Path, bundle_root: Path, repo: Path, recompute: bool):
    res = FileResult(path)
    raw = path.read_text()
    trailing_nl = raw.endswith("\n")
    lines = raw.split("\n")
    if trailing_nl:
        lines = lines[:-1]
    if not lines:
        res.state = "empty"
        return res

    header = lines[0]
    body = lines[1:]
    if any(l == "" for l in body):
        raise SystemExit("%s: blank line inside the journal — refusing" % path)

    if header == V.RESULTS_HEADER:
        if not recompute:
            res.state = "already-migrated"
            res.rows = len(body)
            return res
        res.state = "recomputed"
        legacy = [_strip_new(l.split("\t"), path) for l in body]
    elif header == V.LEGACY_HEADER:
        res.state = "migrated"
        legacy = []
        for l in body:
            c = l.split("\t")
            if len(c) != len(V.LEGACY_COLS):
                raise SystemExit("%s: row has %d fields, expected %d: %.80r"
                                 % (path, len(c), len(V.LEGACY_COLS), l))
            legacy.append(c)
    else:
        raise SystemExit("%s: unrecognised header:\n  %r" % (path, header))

    res.rows = len(legacy)
    out = [migrate_row(c, bundle_root, repo, res.stats) for c in legacy]

    # ---- verification (runs in dry-run too) ------------------------------
    assert len(out) == len(legacy), "row count changed"
    idx = V.LEGACY_COLS.index("peak_gb")
    for old, new in zip(legacy, out):
        if len(new) != len(V.RESULTS_COLS):
            raise SystemExit("%s: produced %d fields for run_id=%s"
                             % (path, len(new), old[0]))
        if new[: idx + 1] != old[: idx + 1] or new[idx + 4:] != old[idx + 1:]:
            raise SystemExit("%s: original values not preserved for run_id=%s"
                             % (path, old[0]))
        for v in new:
            if v == "":
                raise SystemExit("%s: empty value in run_id=%s" % (path, old[0]))
            if "\t" in v or "\n" in v or "\r" in v:
                raise SystemExit("%s: tab/newline inside a value, run_id=%s"
                                 % (path, old[0]))

    res.text = "\n".join([V.RESULTS_HEADER] + ["\t".join(r) for r in out]) + "\n"
    res.changed = res.text != raw
    if not res.changed:
        res.state = "already-migrated"
    return res


def _strip_new(cols, path):
    """Drop the three derived columns from an already-migrated row."""
    if len(cols) != len(V.RESULTS_COLS):
        raise SystemExit("%s: row has %d fields, expected %d"
                         % (path, len(cols), len(V.RESULTS_COLS)))
    i = V.RESULTS_COLS.index("req_counts")
    return cols[:i] + cols[i + 3:]


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def report(res: FileResult, repo: Path, verbose: bool):
    rel = res.path.relative_to(repo)
    s = res.stats
    if res.state == "already-migrated" and not s:
        print("  [skip] %-78s %3d rows  already at 23 columns" % (rel, res.rows))
        return
    flag = "" if res.changed else "  (no change)"
    print("  [%s] %s%s" % (res.state, rel, flag))
    print("      rows %d   backfilled %d   na %d"
          % (res.rows, s["backfill_real"], s["backfill_na"]))
    sev = {k[9:]: v for k, v in s.items() if k.startswith("severity:")}
    print("      severity: " + ", ".join("%s=%d" % kv for kv in sorted(sev.items())))
    if verbose:
        vd = {k[8:]: v for k, v in s.items() if k.startswith("verdict:")}
        print("      verdicts: " + ", ".join("%s=%d" % kv for kv in sorted(vd.items())))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--apply", action="store_true",
                    help="actually write the files (default is a dry run)")
    ap.add_argument("--recompute", action="store_true",
                    help="re-derive req_counts/validity/knobs on files that are "
                         "already at 23 columns")
    ap.add_argument("--bundle-root", default=str(REPO), type=Path,
                    help="checkout that holds the gitignored results/**/data/ "
                         "bundles (default: this repo)")
    ap.add_argument("--repo", default=str(REPO), type=Path,
                    help="repo whose results/ is migrated (default: this repo)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print the full verdict breakdown per file")
    args = ap.parse_args(argv)

    repo = args.repo.resolve()
    bundle_root = args.bundle_root.resolve()
    paths = sorted(repo.glob("results/*/*/*/results.tsv"))
    if not paths:
        sys.exit("no results/*/*/*/results.tsv under %s" % repo)

    print("migrate_results_tsv: %d journals under %s" % (len(paths), repo))
    print("bundles read (read-only) from %s" % bundle_root)
    print("mode: %s%s\n" % ("APPLY" if args.apply else "DRY-RUN",
                            " +recompute" if args.recompute else ""))

    total = Counter()
    results = []
    for p in paths:
        res = migrate_file(p, bundle_root, repo, args.recompute)
        results.append(res)
        total.update(res.stats)
        total["rows"] += res.rows
        report(res, repo, args.verbose)

    print("\n--- totals ---")
    print("rows: %d   backfilled from bundles: %d   na (no bundle): %d"
          % (total["rows"], total["backfill_real"], total["backfill_na"]))
    print("verdict distribution (recorded only — no status was changed):")
    for k, v in sorted((k[8:], v) for k, v in total.items() if k.startswith("verdict:")):
        print("   %-28s %4d" % (k, v))
    print("severity roll-up:")
    for k, v in sorted((k[9:], v) for k, v in total.items() if k.startswith("severity:")):
        print("   %-28s %4d" % (k, v))
    print("knob fill rate (of %d rows):" % total["rows"])
    for k in KNOB_ORDER:
        n = total["knob:" + k]
        print("   %-10s %4d  %5.1f%%" % (k, n, 100.0 * n / max(total["rows"], 1)))

    to_write = [r for r in results if r.changed and r.text is not None]
    print("\nfiles that would change: %d" % len(to_write))
    if not args.apply:
        print("dry run — nothing written. Re-run with --apply to commit the change.")
        return 0
    for r in to_write:
        tmp = r.path.with_suffix(".tsv.tmp")
        tmp.write_text(r.text)
        os.replace(tmp, r.path)
        print("  wrote %s" % r.path.relative_to(repo))
    print("wrote %d files." % len(to_write))
    return 0


if __name__ == "__main__":
    sys.exit(main())
