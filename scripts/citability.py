#!/usr/bin/env python3
"""Row-level CITABILITY — "may this results.tsv row's numbers be quoted?"

    uv run scripts/citability.py gate   --tsv T --cfg C [--shape chat] [--level 16]
    uv run scripts/citability.py median --tsv T --exp EXP_ID [--shape chat] [--level 16]
    uv run scripts/citability.py classify --tsv T [--cfg C] [--level 16]

Why this file exists
--------------------
`scripts/lib/validity.py` owns the RULES (docs/validity-contract.md §3/§4): it reads GuideLLM
bundles and produces the `validity` string. This module owns the one question every *consumer*
asks of a row that is already written: promote.sh, validate.sh, suite.sh, run_experiment.sh,
run_experiment_llamacpp.sh, aggregate.py and tune_status.py.

That question used to be answered by five near-identical `def classify(r)` copies embedded in
shell heredocs. All five carried the same three defects, which is exactly what duplication buys:

  1. every copy tested `token in {'no_data','over_roofline'}` against LEVEL-TAGGED tokens, so
     `'no_data@c16' in FATAL` was always False and every fatal row graded merely `suspect`
     (15 rows in the committed corpus are mislabelled by that bug today);
  2. every copy dropped `('ok', 'na')` together, so `validity=na` — contract §3, "rules could
     not be evaluated, NEVER ok" — was read as citable;
  3. `crash` was citable in aggregate.py/tune_status.py whenever `validity` was `na` or `ok`,
     though §5 v1.1 makes crash non-valid for EVERY consumer.

Nothing here re-implements a rule. Severity, the token grammar and the splitter all come from
`scripts/lib/validity.py` (`FATAL_VERDICTS`, `SUSPECT_VERDICTS`, `parse_validity_pairs`,
`split_verdict`). If you are about to hand-roll a `.split('@')` or a `{'no_data', ...}` literal
somewhere else in this repo, import from here instead — that is the whole point.

Level scoping (contract §3 v1.1)
--------------------------------
"Tokens carry the level they refer to ... Consumers gate on the level they actually cite."
`classify_row(row)` is row-wide and strictest (for a characterization table or a full-sweep
suite report). `classify_row(row, level=16)` judges the row **as evidence for c16 only**:
`low_sample@c1` and `no_data@c32` no longer condemn a c16 claim, while row-wide tokens
(`nonmonotonic`) and anything tagged `@c16` still do. Nothing is swept under the rug — the
callers report the other-level problems, they just do not block on them.
"""
from __future__ import annotations

import argparse
import csv
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib.validity import (  # noqa: E402  — the single source of truth for the rules
    FATAL_VERDICTS,
    NA,
    STATUS_CRASH,
    STATUS_SUSPECT,
    STATUS_VOID,
    parse_validity_pairs,
)

# Citability classes, worst first. `crash` is its own class rather than a flavour of `void`
# because it is an operator signal (the box broke) as well as a data verdict.
CRASH = STATUS_CRASH        # "crash"  — engine wedge; non-valid for every consumer (§5 v1.1)
VOID = STATUS_VOID          # "void"   — not data
SUSPECT = STATUS_SUSPECT    # "suspect"— measured, but an invariant questions it
VALID = "valid"

#: Worst-to-best. `_rank` uses this for latching.
CITE_ORDER = (CRASH, VOID, SUSPECT, VALID)
NON_CITABLE = frozenset({CRASH, VOID, SUSPECT})


def _rank(cite: str) -> int:
    try:
        return CITE_ORDER.index(cite)
    except ValueError:
        return 0            # unknown -> treat as the worst; never as citable


def worst(*cites: str) -> str:
    return min((c for c in cites if c), key=_rank, default=VALID)


def unevaluated(row) -> bool:
    """True when the row's `validity` is `na` — contract §3: "rules could not be evaluated
    (no bundle) — never `ok`". `lib.validity.parse_validity` maps `na` onto `ok` for its own
    purposes, so the raw cell has to be read before parsing, in exactly one place: here."""
    raw = (row.get("validity") or "").strip().lower()
    return raw in ("", NA)


def verdict_pairs(row, level=None):
    """The row's verdict tokens as `(base, level_or_None)`, optionally scoped to one level.

    Scoped means: row-wide tokens (level None, e.g. `nonmonotonic`) plus tokens tagged with
    exactly `level`. `ok` is dropped. Splitting is `lib.validity.split_verdict`'s job.
    """
    if unevaluated(row):
        return []
    pairs = [(b, lv) for b, lv in parse_validity_pairs(row.get("validity")) if b and b != "ok"]
    if level is None:
        return pairs
    return [(b, lv) for b, lv in pairs if lv is None or lv == int(level)]


def classify_row(row, level=None) -> str:
    """`crash` | `void` | `suspect` | `valid` for one results.tsv row.

    `level=None` — row-wide, the strictest reading: every token counts and a `status` of
    void/suspect is honoured even if the tokens were lost.
    `level=N` — judge the row as evidence for concurrency N only (contract §3 v1.1). Tokens
    tagged at other levels do not decide the answer; a `status` downgrade caused solely by
    those tokens likewise does not (the caller reports it via `other_level_flags`).

    A fatal token that BEARS ON the cited level is always `void`. `crash` always wins.
    """
    status = (row.get("status") or "").strip().lower()
    if status == CRASH:
        return CRASH

    pairs = verdict_pairs(row, level)
    if any(b in FATAL_VERDICTS for b, _ in pairs):
        return VOID
    if unevaluated(row):
        # §3: `na` is "rules could not be evaluated", never `ok`. A void STATUS on top of an
        # unevaluable row is still void — there is no token that could exonerate it.
        return VOID if status == VOID else SUSPECT
    if level is None:
        if status == VOID:
            return VOID
        if status == SUSPECT:
            return SUSPECT
    if pairs:
        return SUSPECT     # known-suspect OR an unrecognized token -> conservative
    return VALID


def other_level_flags(row, level) -> list:
    """Verdict tokens the row carries that do NOT bear on `level` — the ones a level-scoped
    gate must REPORT but not block on. Empty when `level` is None."""
    if level is None:
        return []
    keep = {tok for tok in _tokens(row)}
    scoped = {_fmt(b, lv) for b, lv in verdict_pairs(row, level)}
    return sorted(keep - scoped)


def _tokens(row) -> list:
    return [_fmt(b, lv) for b, lv in verdict_pairs(row, None)]


def _fmt(base, lv) -> str:
    return base if lv is None else "%s@c%d" % (base, lv)


def severity(cite: str) -> str:
    """One-word reason a caller can print. Kept tiny on purpose."""
    return {CRASH: "engine wedge", VOID: "not data", SUSPECT: "not citable"}.get(cite, "ok")


# ── results.tsv access ────────────────────────────────────────────────────────
def read_rows(tsv) -> list:
    try:
        with open(tsv, newline="") as f:
            return list(csv.DictReader(f, delimiter="\t"))
    except FileNotFoundError:
        return []


def level_ran(row, level) -> bool:
    """Did this row actually run concurrency `level`? `na` = the level was never attempted;
    a real number or the `hang` sentinel both mean it ran (contract §2)."""
    cell = (row.get("tps_c%d" % int(level)) or "").strip().lower()
    return cell not in ("", NA)


def parse_tps(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def describe(row, cite) -> str:
    return "  %-24s %-16s %-7s validity=%s req_counts=%s" % (
        row.get("run_id", "?"), row.get("shape", "?"), cite,
        row.get("validity", NA), row.get("req_counts", NA))


# ── `gate` — promote.sh / validate.sh ─────────────────────────────────────────
#
# THE GATE RULE (defect #7; see also promote.sh's header).
#
# A promotion cites ONE number: the tuning objective, median c16 in the chat shape
# (AGENTS.md hard rule 2, "c16 = the tuning objective"). The old gate refused if ANY row
# sharing the config_hash was void/suspect, which on the committed corpus blocks 14 of 92
# config groups — 9 of them holding 4-6 perfectly valid rows, e.g. a chat-c16 promotion
# blocked by a starved *coder* full-sweep row that the promotion never quotes. A gate that
# is wrong that often is a gate operators switch off, and then it protects nothing.
#
# So the rows are partitioned by what they can possibly support:
#
#   OBJECTIVE rows  shape starts with the objective shape AND the objective level actually
#                   ran. These are the evidence. The gate is:
#                     * at least one objective row must be CITABLE AT THE OBJECTIVE LEVEL
#                       (contract §3 v1.1: gate on the level you actually cite), and
#                     * no objective row may be FATAL at that level — one `no_data@c16` or
#                       `over_roofline@c16` blocks absolutely, however many clean rows sit
#                       beside it, because it says the cited number itself is not data.
#                     * a `crash` objective row blocks the same way: §5 makes crash
#                       non-valid for every consumer.
#   OTHER rows      another shape, or a row that never ran the objective level. Problems
#                   here are REPORTED loudly (and recorded in the promoted artifact), never
#                   blocking. They are not the claim being made.
#
# Suspect-at-the-objective-level rows do not block on their own as long as a citable
# objective row exists, but they are always listed. Zero objective rows at all is a refusal:
# a promotion with nothing behind it is the same defect as one behind a bad number.
#
# FALLBACK, so the default objective never becomes an unpassable gate for a campaign that
# legitimately never ran it (the ds4 / llama.cpp host backends bench `levels=1` only — 9 real
# config groups). If no row of this config ran the objective level, the gate falls back to the
# highest level that WAS run, and says so on its first output line; same for the shape. This
# mirrors run_experiment.sh's long-standing rule ("objective is c16; fall back to c1 only when
# c16 was never a RUN level"). It relaxes WHICH number is gated, never WHETHER it is gated.
def cmd_gate(args) -> int:
    tsv, cfg = args.tsv, args.cfg
    level = None if args.level in (None, "", "none") else int(args.level)
    shape = (args.shape or "").strip()

    if not Path(tsv).exists():
        print("blocked")
        print("no results.tsv for this model at %s" % tsv)
        return 1
    rows = [r for r in read_rows(tsv) if (r.get("config_hash") or "") == cfg]
    if not rows:
        print("blocked")
        print("NO benchmark rows in results.tsv for config_hash %s — nothing supports this "
              "promotion." % cfg)
        print("(a promotion with no supporting measurement is the same defect as one behind "
              "a bad number)")
        return 1

    notes = []
    shaped = [r for r in rows if not shape or (r.get("shape") or "").startswith(shape)]
    if shape and not shaped:
        notes.append("no `%s` row for this config — gating on every shape instead" % shape)
        shaped, shape = rows, ""
    if level is not None and not any(level_ran(r, level) for r in shaped):
        ran = sorted({lv for r in shaped for lv in (1, 4, 8, 16, 32) if level_ran(r, lv)})
        if ran:
            notes.append("c%d was never a RUN level for this config — gating on c%d, the "
                         "highest level it did run" % (level, ran[-1]))
            level = ran[-1]
        else:
            notes.append("this config ran NO concurrency level — gating row-wide")
            level = None

    objective, other = [], []
    for r in rows:
        is_obj = (not shape or (r.get("shape") or "").startswith(shape)) and \
                 (level is None or level_ran(r, level))
        (objective if is_obj else other).append(r)

    obj_cls = [(r, classify_row(r, level)) for r in objective]
    oth_cls = [(r, classify_row(r, None)) for r in other]

    n_valid = sum(1 for _, c in obj_cls if c == VALID)
    fatal = [(r, c) for r, c in obj_cls if c in (VOID, CRASH)]
    suspect = [(r, c) for r, c in obj_cls if c == SUSPECT]
    warn = [(r, c) for r, c in oth_cls if c != VALID]

    objlbl = "%s c%s" % (shape or "any", level if level is not None else "*")
    summary = ("objective=%s rows=%d objective_rows=%d valid=%d suspect=%d void/crash=%d "
               "other_rows=%d other_flagged=%d" % (
                   objlbl, len(rows), len(objective), n_valid, len(suspect), len(fatal),
                   len(other), len(warn)))

    detail = ["  objective fallback: %s" % n for n in notes]
    if fatal:
        detail.append("%d objective row(s) are NOT DATA at %s (fatal — blocks absolutely):"
                      % (len(fatal), objlbl))
        detail += [describe(r, c) for r, c in fatal]
    if suspect:
        detail.append("%d objective row(s) are suspect at %s:" % (len(suspect), objlbl))
        detail += [describe(r, c) for r, c in suspect]
    for r, c in obj_cls:
        flags = other_level_flags(r, level)
        if c == VALID and flags:
            detail.append("  note: %s is citable at %s; flagged only elsewhere: %s"
                          % (r.get("run_id", "?"), objlbl, "+".join(flags)))
    if warn:
        detail.append("WARNING — %d supporting row(s) OUTSIDE the objective are flagged. They "
                      "do NOT block this promotion (it does not cite them), but the campaign "
                      "record is incomplete:" % len(warn))
        detail += [describe(r, c) for r, c in warn]

    blocked = bool(fatal) or n_valid == 0
    if blocked and n_valid == 0 and not fatal:
        detail.append("no CITABLE objective row: nothing measured %s cleanly, so there is no "
                      "number to promote on" % objlbl)

    print("blocked" if blocked else "ok")
    print(summary)
    for line in detail:
        print(line)
    print("ids=" + ",".join(r.get("run_id", "?") for r, _ in fatal + suspect))
    print("warnids=" + ",".join(r.get("run_id", "?") for r, _ in warn))
    return 1 if blocked else 0


# ── `median` — run_experiment.sh / run_experiment_llamacpp.sh ─────────────────
# Prints ONE whitespace-separated line the shell reads with `read -r`:
#   c1 c16 n void suspect crash rows obj lone verdict otherlvl
def cmd_median(args) -> int:
    level = int(args.level)
    rows = read_rows(args.tsv)
    mine = [r for r in rows
            if args.exp in (r.get("notes") or "")
            and (r.get("shape") or "").startswith(args.shape)]

    cls = [(r, classify_row(r, level)) for r in mine]
    n_void = sum(1 for _, c in cls if c == VOID)
    n_suspect = sum(1 for _, c in cls if c == SUSPECT)
    n_crash = sum(1 for _, c in cls if c == CRASH)
    valid = [r for r, c in cls if c == VALID]
    # Rows that ARE citable for the objective but carry a flag at some other level. Reported
    # so a clean-looking median never hides the fact that the run was structurally thin
    # somewhere else (contract §3 v1.1: gate on the level you cite, report the rest).
    n_other = sum(1 for r, c in cls if c == VALID and other_level_flags(r, level))

    c1 = [v for v in (parse_tps(r.get("tps_c1")) for r in valid) if v is not None]
    c16 = [v for v in (parse_tps(r.get("tps_c%d" % level)) for r in valid) if v is not None]
    obj_name, obj = ("c%d" % level, c16) if c16 else ("c1", c1)
    n = len(obj)
    if n == 0:
        verdict = "no_valid_data"
    elif n == 1:
        verdict = "insufficient"
    elif n < len(mine) or n_void or n_suspect or n_crash:
        verdict = "partial"
    else:
        verdict = "ok"

    def med(xs):
        return round(statistics.median(xs), 2) if xs else "na"

    print(med(c1) if n >= 2 else "na",
          med(c16) if n >= 2 else "na",
          n, n_void, n_suspect, n_crash, len(mine), obj_name,
          (round(obj[0], 2) if n == 1 else "na"), verdict, n_other)
    return 0


# ── `classify` — ad-hoc auditing / test harnesses ─────────────────────────────
def cmd_classify(args) -> int:
    level = None if args.level in (None, "", "none") else int(args.level)
    for r in read_rows(args.tsv):
        if args.cfg and (r.get("config_hash") or "") != args.cfg:
            continue
        print("%s\t%s\t%s\t%s" % (r.get("run_id", "?"), r.get("shape", "?"),
                                  classify_row(r, level), r.get("validity", NA)))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gate", help="promotion / pre-promotion gate on one config_hash")
    g.add_argument("--tsv", required=True)
    g.add_argument("--cfg", required=True)
    g.add_argument("--shape", default="chat")
    g.add_argument("--level", default="16")
    g.set_defaults(fn=cmd_gate)

    m = sub.add_parser("median", help="median over one experiment's rows")
    m.add_argument("--tsv", required=True)
    m.add_argument("--exp", required=True)
    m.add_argument("--shape", default="chat")
    m.add_argument("--level", default="16")
    m.set_defaults(fn=cmd_median)

    c = sub.add_parser("classify", help="print the citability of every row")
    c.add_argument("--tsv", required=True)
    c.add_argument("--cfg")
    c.add_argument("--level", default="none")
    c.set_defaults(fn=cmd_classify)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
