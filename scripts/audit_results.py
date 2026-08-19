#!/usr/bin/env python3
"""audit_results.py — apply the measurement-validity contract to the historical record.

Forensic, READ-ONLY. It never writes `results.tsv`, never touches the GPU, never
serves a model. It reads every `results.tsv` in the repo, maps each row to its
retained GuideLLM bundle via the row's `data` column, and reports the
`docs/validity-contract.md` §3 verdict for every row.

Rules are NOT implemented here. They come from `scripts/lib/validity.py`, which
the contract (§1) makes the single source of truth. This script is a driver.

API this driver calls on `scripts/lib/validity.py` (contract §2–§5). If A1's
library names things differently, the only changes needed are in this file's
`audit_row()` / `bucket()`; no rule logic lives here.

    LEVELS                      tuple[int, ...] = (1, 4, 8, 16, 32)
    LevelStats                  per-level record: .level .successful .incomplete
                                .errored .tps .missing .max_seconds .seed
                                .data_spec .guidellm_version .counts
    level_stats_from_json(path, level) -> LevelStats
    missing_level(level, path)         -> LevelStats(missing=True)
    verdicts(levels, mem_bw_gbs=None, bytes_per_token_gb=None) -> list[str]
    severity(tokens)                   -> "fatal" | "suspect" | "ok"
    status_for(tokens, current_status) -> str      (§5 downgrade; crash wins)
    req_counts(levels)                 -> str      (§2 `req_counts` value)
    knobs(levels, extra=None)          -> str      (§2 `knobs` value)

Usage:
    uv run scripts/audit_results.py --data-root /path/to/main/checkout
    uv run scripts/audit_results.py --format rows > /tmp/rows.tsv
    uv run scripts/audit_results.py --format markdown --mem-bw 273
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))
try:
    import validity  # noqa: E402  (scripts/lib/validity.py — contract §1)
except ImportError as exc:  # pragma: no cover
    sys.exit(
        f"audit_results.py: cannot import scripts/lib/validity.py ({exc}).\n"
        "The validity rules live there and are deliberately not duplicated here.\n"
        "See docs/validity-contract.md §1 and the API block at the top of this file."
    )

LEVEL_COLS = {lvl: f"tps_c{lvl}" for lvl in validity.LEVELS}
PROMOTED_FROM = re.compile(r"promoted from\s+(\S+?\.sh)", re.IGNORECASE)


# ----------------------------------------------------------------- discovery
def find_journals(repo: Path) -> list[Path]:
    return sorted((repo / "results").rglob("results.tsv"))


def read_rows(journal: Path) -> list[dict]:
    # QUOTE_NONE is required: `notes` legitimately contains `"` (quoted flag
    # values, JSON fragments). Default csv quoting would swallow the following
    # rows into one field and silently shrink the audit population.
    with journal.open(newline="") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE))
    for r in rows:
        r["_journal"] = str(journal)
    return rows


def node_mem_bw(repo: Path, node_fp: str) -> float | None:
    """§4: mem_bw_gbs from the node profile. Absent -> None -> check skipped."""
    prof = repo / "results" / node_fp / "node_profile.json"
    if not prof.exists():
        return None
    try:
        doc = json.loads(prof.read_text())
    except Exception:  # noqa: BLE001
        return None
    v = (doc.get("gpu") or {}).get("mem_bw_gbs")
    return float(v) if v else None


# ------------------------------------------------------------- per-row audit
def audit_row(row: dict, data_root: Path, mem_bw: float | None) -> dict:
    """Compute the §3 verdict for one journal row from its retained bundle."""
    rel = (row.get("data") or "na").strip()
    bundle = None if rel in ("", "na", "-") else (data_root / rel)

    tsv_levels = {
        lvl for lvl, col in LEVEL_COLS.items()
        if (row.get(col) or "na").strip() not in ("", "na", "-")
    }
    bundle_levels: set[int] = set()
    if bundle and bundle.is_dir():
        for lvl in validity.LEVELS:
            if (bundle / f"level_c{lvl}.json").exists():
                bundle_levels.add(lvl)

    # A level counts as RUN if the journal published a number for it OR the
    # harness left a bundle for it. The union matters: hand-corrected rows
    # (e.g. the MTP n=4 crash, tps_c16 blanked to `na`) still have the bundle
    # that proves what was actually measured.
    run_levels = sorted(tsv_levels | bundle_levels)

    stats = []
    for lvl in run_levels:
        p = (bundle / f"level_c{lvl}.json") if bundle else None
        if p and p.exists():
            stats.append(validity.level_stats_from_json(p, lvl))
        else:
            stats.append(validity.missing_level(lvl, str(p) if p else "na"))

    auditable = bool(bundle and bundle.is_dir() and bundle_levels)
    if not auditable:
        toks, sev, new_status = ["na"], "unauditable", row.get("status", "na")
        rc = "na"
        kb = "na"
    else:
        toks = validity.verdicts(stats, mem_bw_gbs=mem_bw)
        sev = validity.severity(toks)
        new_status = validity.status_for(toks, (row.get("status") or "").strip())
        rc = validity.req_counts(stats)
        kb = validity.knobs(stats)

    return {
        "run_id": row.get("run_id", "na"),
        "journal": row["_journal"],
        "model": row.get("model", "na"),
        "shape": row.get("shape", "na"),
        "script": (row.get("script") or "na").strip(),
        "status": (row.get("status") or "na").strip(),
        "max_s_tsv": (row.get("max_s") or "na").strip(),
        "bundle": str(bundle) if bundle else "na",
        "auditable": auditable,
        "levels": run_levels,
        "stats": stats,
        "req_counts": rc,
        "knobs": kb,
        "validity": "+".join(toks),
        "severity": sev,
        "new_status": new_status,
        "tps": {lvl: (row.get(LEVEL_COLS[lvl]) or "na").strip() for lvl in validity.LEVELS},
        "notes": (row.get("notes") or "").strip(),
    }


# ------------------------------------------------------------ promotion link
def promoted_finals(repo: Path) -> list[dict]:
    """Every `*_final.sh` runbook plus the tuned runbook it names as its source."""
    out = []
    for f in sorted((repo / "runbooks").rglob("*_final.sh")):
        src = None
        try:
            head = f.read_text(errors="replace").splitlines()[:12]
        except OSError:
            head = []
        for line in head:
            m = PROMOTED_FROM.search(line)
            if m:
                src = m.group(1)
                break
        out.append({
            "final": str(f.relative_to(repo)),
            "promoted_from": src or "na",
        })
    return out


def supporting_rows(audits: list[dict], final: dict) -> list[dict]:
    """Rows whose `script` is the promoted config or the runbook it came from."""
    want = {final["final"], final["promoted_from"]}
    want.discard("na")
    return [a for a in audits if a["script"] in want]


# ---------------------------------------------------------------- reporting
def campaign_of(a: dict) -> str:
    p = Path(a["journal"]).parent
    return f"{p.parent.name}/{p.name}"


def bucket(a: dict) -> str:
    if not a["auditable"]:
        return "unauditable"
    return {"fatal": "void", "suspect": "suspect", "ok": "ok"}[a["severity"]]


def summarise(audits: list[dict], finals: list[dict], mem_bw, out) -> None:
    w = out.write
    total = len(audits)
    b = Counter(bucket(a) for a in audits)
    w(f"rows audited              : {total}\n")
    w(f"  ok                      : {b['ok']}\n")
    w(f"  suspect                 : {b['suspect']}\n")
    w(f"  void                    : {b['void']}\n")
    w(f"  unauditable (no bundle) : {b['unauditable']}\n")
    w(f"roofline mem_bw_gbs       : {mem_bw if mem_bw else 'ABSENT -> over_roofline SKIPPED (§4)'}\n\n")

    w("verdict tokens (rows may carry several)\n")
    tok = Counter(t for a in audits if a["auditable"] for t in a["validity"].split("+"))
    for k, v in tok.most_common():
        w(f"  {k:<16} {v}\n")
    w("\n")

    w("by campaign\n")
    per = defaultdict(Counter)
    for a in audits:
        per[campaign_of(a)][bucket(a)] += 1
    w(f"  {'campaign':<58} {'ok':>4} {'susp':>5} {'void':>5} {'unaud':>6} {'n':>4}\n")
    for c in sorted(per):
        k = per[c]
        w(f"  {c:<58} {k['ok']:>4} {k['suspect']:>5} {k['void']:>5} {k['unauditable']:>6} {sum(k.values()):>4}\n")
    w("\n")

    w("by shape\n")
    per = defaultdict(Counter)
    for a in audits:
        per[a["shape"]][bucket(a)] += 1
    for c in sorted(per):
        k = per[c]
        w(f"  {c:<24} ok={k['ok']:<4} suspect={k['suspect']:<4} void={k['void']:<4} unaud={k['unauditable']:<4} n={sum(k.values())}\n")
    w("\n")

    w("by journal status\n")
    per = defaultdict(Counter)
    for a in audits:
        per[a["status"]][bucket(a)] += 1
    for c in sorted(per):
        k = per[c]
        w(f"  {c:<12} ok={k['ok']:<4} suspect={k['suspect']:<4} void={k['void']:<4} unaud={k['unauditable']:<4} n={sum(k.values())}\n")
    w("\n")

    w("promotion risk — rows supporting each *_final.sh\n")
    for f in finals:
        rows = supporting_rows(audits, f)
        k = Counter(bucket(a) for a in rows)
        flag = "AT RISK" if (k["void"] or k["suspect"]) else ("NO SUPPORTING ROWS" if not rows else "clean")
        w(f"  {f['final']}\n")
        w(f"      from={f['promoted_from']}  rows={len(rows)} ok={k['ok']} suspect={k['suspect']} void={k['void']} unaud={k['unauditable']}  -> {flag}\n")
        for a in rows:
            if bucket(a) in ("void", "suspect"):
                w(f"        {a['run_id']}  {a['shape']}  {a['validity']}  {a['req_counts']}\n")


def emit_rows(audits: list[dict], out) -> None:
    cols = ["run_id", "model", "shape", "status", "new_status", "severity",
            "validity", "req_counts", "max_s_tsv", "knobs", "script", "bundle"]
    out.write("\t".join(cols) + "\n")
    for a in audits:
        out.write("\t".join(str(a[c]) for c in cols) + "\n")


def emit_markdown(audits: list[dict], out) -> None:
    out.write("| run_id | model | shape | status | verdict | req_counts (ok/inc/err) |\n")
    out.write("|---|---|---|---|---|---|\n")
    for a in sorted(audits, key=lambda x: x["run_id"]):
        out.write(f"| `{a['run_id']}` | {a['model']} | {a['shape']} | {a['status']} | "
                  f"`{a['validity']}` | `{a['req_counts']}` |\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-root", default=str(SCRIPT_DIR.parent),
                    help="repo containing results/*/results.tsv and runbooks/ (default: this checkout)")
    ap.add_argument("--data-root", default=None,
                    help="checkout holding the gitignored results/**/data/ bundles (default: --repo-root)")
    ap.add_argument("--mem-bw", type=float, default=None,
                    help="§4 memory bandwidth GB/s. Use ONLY when node_profile.json lacks "
                         "gpu.mem_bw_gbs and the value is documented, not invented.")
    ap.add_argument("--format", choices=("summary", "rows", "markdown"), default="summary")
    args = ap.parse_args()

    repo = Path(args.repo_root).resolve()
    data_root = Path(args.data_root).resolve() if args.data_root else repo

    journals = find_journals(repo)
    if not journals:
        sys.exit(f"no results.tsv under {repo}/results")

    audits = []
    for j in journals:
        node_fp = j.relative_to(repo / "results").parts[0]
        mem_bw = args.mem_bw if args.mem_bw is not None else node_mem_bw(repo, node_fp)
        for row in read_rows(j):
            audits.append(audit_row(row, data_root, mem_bw))

    mem_bw_reported = args.mem_bw if args.mem_bw is not None else node_mem_bw(
        repo, Path(journals[0]).relative_to(repo / "results").parts[0])

    if args.format == "rows":
        emit_rows(audits, sys.stdout)
    elif args.format == "markdown":
        emit_markdown(audits, sys.stdout)
    else:
        summarise(audits, promoted_finals(repo), mem_bw_reported, sys.stdout)

    # non-zero when the historical record contains rows the contract calls void
    return 1 if any(bucket(a) == "void" for a in audits) else 0


if __name__ == "__main__":
    raise SystemExit(main())
