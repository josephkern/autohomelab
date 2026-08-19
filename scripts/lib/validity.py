#!/usr/bin/env python3
"""Measurement-validity rules — the SINGLE source of truth for docs/validity-contract.md.

Nothing else in this repo may re-implement these rules. `scripts/lib/validity.sh` is a thin
bash shim that shells out to this module; the bench scripts, aggregate.py, promote.sh and
run_experiment.sh all consume the schema and the verdicts from here.

Stdlib only, on purpose: this module must be importable and runnable in any context that can
run python, including from inside a bash shim during a benchmark.

CLI:
    python3 scripts/lib/validity.py check --bundle DIR --levels 1,16 \
        --tps 41.2,na,na,151.5,na [--node-profile P] [--model-gb G]
prints one JSON object: {"validity": ..., "req_counts": ..., "status_floor": ...}
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping, Optional, Sequence

__all__ = [
    "RESULTS_COLS", "LEGACY_COLS", "NEW_COLS", "RESULTS_HEADER", "LEGACY_HEADER",
    "LEVEL_COLUMNS", "level_col_index",
    "LevelCounts", "LevelParseError", "parse_level_json", "scan_bundle",
    "verdicts", "format_validity", "parse_validity", "status_floor", "apply_status",
    "format_req_counts", "parse_req_counts", "format_knobs", "parse_knobs",
    "ceiling", "make_ceiling_fn", "read_mem_bw", "parse_tps",
    "AHL_MIN_DATA", "AHL_MIN_SUCCESSFUL", "AHL_DROP_TOL", "AHL_ERR_TOL",
    "AHL_ROOFLINE_SAFETY", "AHL_MIN_MODEL_GB",
    "V_OK", "V_NO_DATA", "V_LOW_SAMPLE", "V_OVER_ROOFLINE", "V_NONMONOTONIC", "V_ERRORED",
    "VERDICT_ORDER", "FATAL_VERDICTS", "SUSPECT_VERDICTS",
    "STATUS_MEASURED", "STATUS_KEEP", "STATUS_DISCARD", "STATUS_CRASH",
    "STATUS_SUSPECT", "STATUS_VOID", "STATUS_VOCAB",
    "NA",
]

NA = "na"

# ---------------------------------------------------------------------------
# Tunable constants (contract sections 3 and 4). Overridable two ways, in order:
#   1. the environment variable of the same name
#   2. reassigning the module attribute (tests, callers)
# Reads happen at CALL time, so exporting AHL_MIN_SUCCESSFUL=40 before invoking
# bench.sh changes the verdicts for that run.
# ---------------------------------------------------------------------------
AHL_MIN_DATA = 5            # successful < this  -> no_data     (fatal)
AHL_MIN_SUCCESSFUL = 20     # successful < this  -> low_sample  (suspect)
AHL_DROP_TOL = 0.10         # higher level > this fraction below a lower one -> nonmonotonic
AHL_ERR_TOL = 0.10          # errored / (successful+errored) > this -> errored
AHL_ROOFLINE_SAFETY = 2.0   # SAFETY multiplier on the bandwidth roofline
AHL_MIN_MODEL_GB = 1.0      # fallback bytes-per-token (GB) when the model size is unknown


def _cfg(name: str, cast):
    """Effective value of a tunable: env var wins, then the module attribute."""
    raw = os.environ.get(name)
    if raw is not None and raw.strip() != "":
        try:
            return cast(raw.strip())
        except (TypeError, ValueError):
            pass
    return cast(globals()[name])


# ---------------------------------------------------------------------------
# Section 2 -- results.tsv schema
# ---------------------------------------------------------------------------
NEW_COLS: list[str] = ["req_counts", "validity", "knobs"]

RESULTS_COLS: list[str] = [
    "run_id", "commit", "node_fp", "model", "shape", "backend", "config_hash", "script",
    "load_s", "max_s", "seed",
    "tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32",
    "peak_gb",
    "req_counts", "validity", "knobs",
    "status", "notes", "data",
]

# The 20 pre-migration columns: identical order, minus the three new ones.
LEGACY_COLS: list[str] = [c for c in RESULTS_COLS if c not in NEW_COLS]

RESULTS_HEADER: str = "\t".join(RESULTS_COLS)
LEGACY_HEADER: str = "\t".join(LEGACY_COLS)

assert len(RESULTS_COLS) == 23, "contract section 2 fixes results.tsv at 23 columns"
assert len(LEGACY_COLS) == 20, "the pre-migration header has 20 columns"

# The fixed tps_c* columns. Unrun levels stay `na` so runs stay comparable.
LEVEL_COLUMNS: tuple[int, ...] = (1, 4, 8, 16, 32)


def level_col_index(level) -> int:
    """Index of `level` in LEVEL_COLUMNS, or -1 if it has no column."""
    try:
        return LEVEL_COLUMNS.index(int(level))
    except (ValueError, TypeError):
        return -1


# ---------------------------------------------------------------------------
# Section 3 verdict + section 6 status vocabularies
# ---------------------------------------------------------------------------
V_OK = "ok"
V_NO_DATA = "no_data"
V_LOW_SAMPLE = "low_sample"
V_OVER_ROOFLINE = "over_roofline"
V_NONMONOTONIC = "nonmonotonic"
V_ERRORED = "errored"

# Emission order == the order of the contract's section 3 table, so that
# `low_sample+nonmonotonic` in the contract's own example is exactly what we print.
VERDICT_ORDER: tuple[str, ...] = (
    V_NO_DATA, V_LOW_SAMPLE, V_OVER_ROOFLINE, V_NONMONOTONIC, V_ERRORED,
)
FATAL_VERDICTS = frozenset({V_NO_DATA, V_OVER_ROOFLINE})
SUSPECT_VERDICTS = frozenset({V_LOW_SAMPLE, V_NONMONOTONIC, V_ERRORED})

STATUS_MEASURED = "measured"
STATUS_KEEP = "keep"
STATUS_DISCARD = "discard"
STATUS_CRASH = "crash"
STATUS_SUSPECT = "suspect"
STATUS_VOID = "void"
STATUS_VOCAB = (
    STATUS_MEASURED, STATUS_KEEP, STATUS_DISCARD, STATUS_CRASH, STATUS_SUSPECT, STATUS_VOID,
)


# ---------------------------------------------------------------------------
# GuideLLM level JSON
# ---------------------------------------------------------------------------
class LevelParseError(ValueError):
    """The level_c<N>.json is missing, unreadable, or not a GuideLLM 0.6.0 bundle."""


@dataclass(frozen=True)
class LevelCounts:
    """Per-level request outcome.

    `ok` / `incomplete` / `errored` are REQUEST counts read from
    `.benchmarks[0].metrics.request_concurrency.<kind>.count`.
    `tps` is `.benchmarks[0].metrics.output_tokens_per_second.successful.mean`
    (None when absent or non-finite).

    `missing` is a 5th field WITH A DEFAULT, so the 4-positional construction named in the
    API spec -- LevelCounts(41, 0, 0, 12.3) -- is unchanged. It marks a level that WAS run
    but whose json is missing/unparseable, which the contract treats as `no_data` while
    still distinguishing it from a genuine zero in `req_counts` (`c32:na`).
    """

    ok: int = 0
    incomplete: int = 0
    errored: int = 0
    tps: Optional[float] = None
    missing: bool = False

    @property
    def total(self) -> int:
        return self.ok + self.incomplete + self.errored


def _finite(value) -> Optional[float]:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _count(node: Mapping, kind: str, required: bool) -> int:
    sub = node.get(kind)
    if not isinstance(sub, Mapping):
        if required:
            raise LevelParseError("metrics.request_concurrency.%s missing" % kind)
        return 0
    raw = sub.get("count")
    if raw is None:
        if required:
            raise LevelParseError("metrics.request_concurrency.%s.count missing" % kind)
        return 0
    try:
        return int(raw)
    except (TypeError, ValueError) as exc:
        raise LevelParseError(
            "metrics.request_concurrency.%s.count not an int" % kind) from exc


def parse_level_json(path) -> LevelCounts:
    """Read one GuideLLM per-level bundle. Raises LevelParseError if it is not usable.

    Field paths verified against all 693 retained bundles on node gb10-1988a9714b4e
    (GuideLLM 0.6.0): every one has exactly one entry in `benchmarks[]` and all four
    source fields present.
    """
    p = Path(path)
    try:
        with p.open("r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError as exc:
        raise LevelParseError("missing: %s" % p) from exc
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LevelParseError("unparseable: %s: %s" % (p, exc)) from exc

    if not isinstance(doc, Mapping):
        raise LevelParseError("not a json object: %s" % p)
    benchmarks = doc.get("benchmarks")
    if (not isinstance(benchmarks, Sequence) or isinstance(benchmarks, (str, bytes))
            or not benchmarks):
        raise LevelParseError("no benchmarks[] in %s" % p)
    bench = benchmarks[0]
    if not isinstance(bench, Mapping):
        raise LevelParseError("benchmarks[0] is not an object in %s" % p)
    metrics = bench.get("metrics")
    if not isinstance(metrics, Mapping):
        raise LevelParseError("benchmarks[0].metrics missing in %s" % p)

    rc = metrics.get("request_concurrency")
    if not isinstance(rc, Mapping):
        raise LevelParseError("benchmarks[0].metrics.request_concurrency missing in %s" % p)
    ok = _count(rc, "successful", required=True)
    incomplete = _count(rc, "incomplete", required=False)
    errored = _count(rc, "errored", required=False)

    tps = None
    otps = metrics.get("output_tokens_per_second")
    if isinstance(otps, Mapping):
        succ = otps.get("successful")
        if isinstance(succ, Mapping):
            tps = _finite(succ.get("mean"))

    return LevelCounts(ok=ok, incomplete=incomplete, errored=errored, tps=tps)


def scan_bundle(bundle_dir, levels: Iterable,
                tps: Optional[Mapping] = None) -> dict:
    """Read `level_c<N>.json` for each RUN level.

    A level whose json is absent or unparseable comes back as LevelCounts(missing=True) --
    the contract's `no_data`. Levels NOT listed in `levels` are simply absent from the
    result, so they are never mistaken for a zero.

    `tps` optionally overrides the per-level tok/s with the value the caller is actually
    writing into results.tsv (used only when that value is a finite number).
    """
    bundle = Path(bundle_dir)
    out: dict = {}
    for raw in levels:
        lvl = int(raw)
        try:
            counts = parse_level_json(bundle / ("level_c%d.json" % lvl))
        except LevelParseError:
            counts = LevelCounts(missing=True)
        if tps is not None and lvl in tps:
            override = _finite(tps[lvl])
            if override is not None:
                counts = LevelCounts(counts.ok, counts.incomplete, counts.errored,
                                     override, counts.missing)
        out[lvl] = counts
    return out


# ---------------------------------------------------------------------------
# Section 4 -- physical ceiling (roofline)
# ---------------------------------------------------------------------------
def ceiling(level, mem_bw_gbs, bytes_per_token_gb=None, safety=None) -> float:
    """SAFETY * level * (mem_bw_GB_s / bytes_per_token_GB).

    Returns +inf (i.e. the check can never trip) when `mem_bw_gbs` is missing or
    nonsensical -- never invent a bandwidth number (contract section 4).
    `bytes_per_token_gb` falls back to AHL_MIN_MODEL_GB when unknown, giving a loose but
    sound bound. `safety` defaults to AHL_ROOFLINE_SAFETY (2.0).
    """
    if safety is None:
        safety = _cfg("AHL_ROOFLINE_SAFETY", float)
    bw = _finite(mem_bw_gbs)
    if bw is None or bw <= 0:
        return math.inf
    bpt = _finite(bytes_per_token_gb)
    if bpt is None or bpt <= 0:
        bpt = _cfg("AHL_MIN_MODEL_GB", float)
    lvl = _finite(level)
    if lvl is None or lvl <= 0:
        return math.inf
    return float(safety) * lvl * (bw / bpt)


def make_ceiling_fn(mem_bw_gbs, bytes_per_token_gb=None,
                    safety=None) -> Optional[Callable]:
    """A `ceiling_fn(level)` for verdicts(), or None when the roofline check must be
    SKIPPED because the node profile carries no usable `gpu.mem_bw_gbs`."""
    bw = _finite(mem_bw_gbs)
    if bw is None or bw <= 0:
        return None
    return lambda level: ceiling(level, bw, bytes_per_token_gb, safety)


def read_mem_bw(node_profile_path) -> Optional[float]:
    """`gpu.mem_bw_gbs` from a node_profile.json, or None if absent/unreadable."""
    if not node_profile_path:
        return None
    try:
        with Path(node_profile_path).open("r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(doc, Mapping):
        return None
    gpu = doc.get("gpu")
    if isinstance(gpu, Mapping) and gpu.get("mem_bw_gbs") is not None:
        return _finite(gpu.get("mem_bw_gbs"))
    return _finite(doc.get("mem_bw_gbs"))


# ---------------------------------------------------------------------------
# Section 3 -- verdicts
# ---------------------------------------------------------------------------
def verdicts(levels: Mapping, ceiling_fn: Optional[Callable] = None) -> list:
    """The contract section 3 verdict tokens for one results.tsv row.

    `levels` maps concurrency -> LevelCounts for the levels that were RUN. A key mapped to
    None (or anything that is not a LevelCounts) is treated as UNRUN and skipped entirely:
    an unrun level is never a zero. `ceiling_fn` is None when the roofline check must be
    skipped (no mem_bw recorded for the node).
    """
    min_data = _cfg("AHL_MIN_DATA", int)
    min_ok = _cfg("AHL_MIN_SUCCESSFUL", int)
    drop_tol = _cfg("AHL_DROP_TOL", float)
    err_tol = _cfg("AHL_ERR_TOL", float)

    run = {int(k): v for k, v in (levels or {}).items() if isinstance(v, LevelCounts)}
    found = set()

    for lvl in sorted(run):
        c = run[lvl]
        # no_data and low_sample are mutually exclusive PER LEVEL -- report the more severe.
        if c.missing or c.ok < min_data:
            found.add(V_NO_DATA)
        elif c.ok < min_ok:
            found.add(V_LOW_SAMPLE)

        denom = c.ok + c.errored
        if denom > 0 and (c.errored / denom) > err_tol:
            found.add(V_ERRORED)

        if ceiling_fn is not None and c.tps is not None and not c.missing:
            cap = ceiling_fn(lvl)
            if cap is not None and math.isfinite(cap) and c.tps > cap:
                found.add(V_OVER_ROOFLINE)

    # nonmonotonic: ANY higher level more than AHL_DROP_TOL below ANY lower one.
    curve = [(lvl, run[lvl].tps) for lvl in sorted(run)
             if run[lvl].tps is not None and not run[lvl].missing]
    for i, (_lo, t_lo) in enumerate(curve):
        if t_lo is None or t_lo <= 0:
            continue
        if any(t_hi < t_lo * (1.0 - drop_tol) for _hi, t_hi in curve[i + 1:]):
            found.add(V_NONMONOTONIC)
            break

    out = [tok for tok in VERDICT_ORDER if tok in found]
    return out or [V_OK]


def format_validity(verds: Iterable) -> str:
    """`ok`, or the `+`-joined verdict tokens in contract order."""
    seen = {v for v in (verds or []) if v and v != V_OK}
    ordered = [tok for tok in VERDICT_ORDER if tok in seen]
    ordered.extend(sorted(seen - set(VERDICT_ORDER)))
    return "+".join(ordered) if ordered else V_OK


def parse_validity(s: Optional[str]) -> list:
    """Inverse of format_validity. `ok`/`na`/empty -> ["ok"]."""
    if not s:
        return [V_OK]
    s = s.strip()
    if s in ("", NA, V_OK):
        return [V_OK]
    return [tok for tok in (p.strip() for p in s.split("+")) if tok]


# ---------------------------------------------------------------------------
# Section 5 -- enforcement
# ---------------------------------------------------------------------------
def status_floor(verds: Iterable) -> str:
    """`void` (any fatal verdict) / `suspect` (any suspect verdict) / `ok`."""
    seen = set(verds or [])
    if seen & FATAL_VERDICTS:
        return "void"
    if seen & SUSPECT_VERDICTS:
        return "suspect"
    return "ok"


def apply_status(current_status: Optional[str], floor: str) -> str:
    """Contract section 5 precedence. A crash ALWAYS wins: an already-`crash` row keeps
    status=crash and records its verdict in `validity` instead. Otherwise a fatal floor
    forces `void`, a suspect floor forces `suspect`, and an `ok` floor leaves the caller's
    status untouched (`measured`, `keep`, `discard`, ...)."""
    cur = (current_status or "").strip() or STATUS_MEASURED
    if cur == STATUS_CRASH:
        return STATUS_CRASH
    if floor == "void":
        return STATUS_VOID
    if floor == "suspect":
        return STATUS_SUSPECT
    return cur


# ---------------------------------------------------------------------------
# Section 2 -- req_counts encoding: c1:41/0/0;c16:118/4/0
# (`c<N>:na` = the level was run but its json is missing/unparseable)
# ---------------------------------------------------------------------------
_REQ_CHUNK = re.compile(r"^c(\d+):(?:na|(\d+)/(\d+)/(\d+))$")


def format_req_counts(levels: Mapping) -> str:
    parts = []
    run = {int(k): v for k, v in (levels or {}).items() if isinstance(v, LevelCounts)}
    for lvl in sorted(run):
        c = run[lvl]
        parts.append("c%d:%s" % (lvl, NA) if c.missing
                     else "c%d:%d/%d/%d" % (lvl, c.ok, c.incomplete, c.errored))
    return ";".join(parts) if parts else NA


def parse_req_counts(s: Optional[str]) -> dict:
    """Inverse of format_req_counts. Counts round-trip exactly; `tps` is not carried by
    the encoding and always comes back None."""
    out: dict = {}
    if s is None:
        return out
    s = s.strip()
    if s == "" or s.lower() == NA:
        return out
    for chunk in s.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = _REQ_CHUNK.match(chunk)
        if not m:
            raise ValueError("bad req_counts chunk: %r" % chunk)
        lvl = int(m.group(1))
        if m.group(2) is None:
            out[lvl] = LevelCounts(missing=True)
        else:
            out[lvl] = LevelCounts(int(m.group(2)), int(m.group(3)), int(m.group(4)))
    return out


# ---------------------------------------------------------------------------
# Section 2 -- knobs encoding: levels=1,16,max_s=180,seed=42,...
# Values may themselves contain commas (`levels=1,16`), so the split is on a comma that
# is FOLLOWED BY `key=`. That is the only unambiguous reading of the specified format.
# ---------------------------------------------------------------------------
_KNOB_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_.\-]*$")
_KNOB_SPLIT = re.compile(r",(?=[A-Za-z_][A-Za-z0-9_.\-]*=)")


def _knob_value(v) -> str:
    if v is None:
        return NA
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        s = repr(round(v, 6))
        if s.endswith(".0"):
            s = s[:-2]
    elif isinstance(v, (list, tuple)):
        s = ",".join(_knob_value(x) for x in v)
    else:
        s = str(v)
    s = s.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
    return s if s else NA


def format_knobs(**kw) -> str:
    """`k=v` comma-joined, in the order the kwargs were given. Empty -> `na`.
    Tabs/newlines are stripped so a value can never break the TSV."""
    parts = []
    for k, v in kw.items():
        if not _KNOB_KEY.match(k):
            raise ValueError("bad knob key: %r" % k)
        parts.append("%s=%s" % (k, _knob_value(v)))
    return ",".join(parts) if parts else NA


def parse_knobs(s: Optional[str]) -> dict:
    """Inverse of format_knobs. Values stay strings (`levels` keeps its embedded commas)."""
    out: dict = {}
    if not s:
        return out
    s = s.strip()
    if s == "" or s.lower() == NA:
        return out
    for chunk in _KNOB_SPLIT.split(s):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        k, _, v = chunk.partition("=")
        out[k.strip()] = v
    return out


def parse_tps(value) -> Optional[float]:
    """A results.tsv tok/s cell -> float, or None for `na`/`hang`/anything non-finite."""
    if value is None:
        return None
    if isinstance(value, str):
        v = value.strip().lower()
        if v in ("", NA, "hang", "crash", "none", "null", "nan"):
            return None
        value = v
    return _finite(value)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _cmd_check(args) -> int:
    levels = [int(x) for x in str(args.levels).replace(" ", "").split(",") if x != ""]

    tps_override: dict = {}
    if args.tps:
        cells = [c.strip() for c in str(args.tps).split(",")]
        if len(cells) == len(levels) and len(cells) != len(LEVEL_COLUMNS):
            # convenience form: one value per RUN level
            for lvl, cell in zip(levels, cells):
                tps_override[lvl] = parse_tps(cell)
        else:
            # documented form: the 5 fixed tps_c* cells, c1,c4,c8,c16,c32
            for idx, cell in enumerate(cells[:len(LEVEL_COLUMNS)]):
                tps_override[LEVEL_COLUMNS[idx]] = parse_tps(cell)

    counts = scan_bundle(args.bundle, levels, tps_override)
    cfn = make_ceiling_fn(read_mem_bw(args.node_profile), args.model_gb)
    verds = verdicts(counts, cfn)
    print(json.dumps({
        "validity": format_validity(verds),
        "req_counts": format_req_counts(counts),
        "status_floor": status_floor(verds),
    }, separators=(",", ":")))
    return 0


def _cmd_header(args) -> int:
    print(LEGACY_HEADER if args.legacy else RESULTS_HEADER)
    return 0


def _cmd_level(args) -> int:
    try:
        c = parse_level_json(args.path)
    except LevelParseError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("%d/%d/%d" % (c.ok, c.incomplete, c.errored))
    return 0


def _cmd_knobs(args) -> int:
    kw: dict = {}
    for item in args.pairs:
        if "=" not in item:
            print("bad knob (want k=v): %r" % item, file=sys.stderr)
            return 2
        k, _, v = item.partition("=")
        kw[k.strip()] = v
    try:
        print(format_knobs(**kw))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


def main(argv: Optional[Sequence] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="validity", description="measurement-validity rules (docs/validity-contract.md)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("check", help="validity verdicts for one benchmark bundle")
    c.add_argument("--bundle", required=True, help="bundle dir holding level_c<N>.json")
    c.add_argument("--levels", required=True, help="comma list of RUN levels, e.g. 1,16")
    c.add_argument("--tps", default="",
                   help="the 5 tps_c* cells (c1,c4,c8,c16,c32); `na`/`hang` allowed")
    c.add_argument("--node-profile", default="", help="node_profile.json for gpu.mem_bw_gbs")
    c.add_argument("--model-gb", default=None, type=float,
                   help="active weight bytes per token, GB")
    c.set_defaults(func=_cmd_check)

    h = sub.add_parser("header", help="print the results.tsv header")
    h.add_argument("--legacy", action="store_true", help="the 20-column pre-migration header")
    h.set_defaults(func=_cmd_header)

    lv = sub.add_parser("level", help="print ok/incomplete/errored for one level json")
    lv.add_argument("path")
    lv.set_defaults(func=_cmd_level)

    k = sub.add_parser("knobs", help="normalize k=v pairs into the knobs string")
    k.add_argument("pairs", nargs="*")
    k.set_defaults(func=_cmd_knobs)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
