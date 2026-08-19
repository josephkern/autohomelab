#!/usr/bin/env python3
"""Measurement-validity rules — the SINGLE source of truth for docs/validity-contract.md.

Nothing else in this repo may re-implement these rules. `scripts/lib/validity.sh` is a thin
bash shim that shells out to this module; the bench scripts, aggregate.py, promote.sh and
run_experiment.sh all consume the schema and the verdicts from here.

Stdlib only, on purpose: this module must be importable and runnable in any context that can
run python, including from inside a bash shim during a benchmark.

Amendment batch 1 (orchestrator, 2026-08-19) is folded in:
  1. low_sample is a TOKENS-generated rule, not a request-count rule (A9: request count does
     not correlate with reproducibility; CV is 0.39% at n<10 vs 0.56% at 20<=n<50).
  2. new `survivorship` verdict — GuideLLM's successful.mean silently drops the slow half.
  3. per-level verdict tokens carry their level: `low_sample@c1`, `no_data@c32`.
  4. hung levels are SCORED, not skipped; a level is "run" if the journal published a cell
     OR a bundle file exists.
  5. `nonmonotonic` is ADJACENT-ONLY.
  6. knobs list values join with `|`, never a comma.
  7. AHL_ROOFLINE_SAFETY 2.0 -> 3.0 (MTP accepted length reaches 2.69 on this node).

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
    "LEVEL_COLUMNS", "level_col_index", "level_meta",
    "assess_bundle", "BundleAssessment", "COLUMNS", "STATUSES", "SAFETY",
    "EXIT_OK", "EXIT_CRASH", "EXIT_INVALID",
    "LevelCounts", "LevelParseError", "parse_level_json", "scan_bundle",
    "verdicts", "format_validity", "parse_validity", "parse_validity_pairs",
    "split_verdict", "verdict_base", "verdict_level", "tag_verdict",
    "status_floor", "apply_status",
    "format_req_counts", "parse_req_counts", "format_knobs", "parse_knobs",
    "ceiling", "make_ceiling_fn", "read_mem_bw", "parse_tps", "min_requests_for_level",
    "AHL_MIN_DATA", "AHL_MIN_SUCCESSFUL", "AHL_MIN_TOKENS", "AHL_DROP_TOL", "AHL_ERR_TOL",
    "AHL_ROOFLINE_SAFETY", "AHL_MIN_MODEL_GB",
    "V_OK", "V_NO_DATA", "V_LOW_SAMPLE", "V_OVER_ROOFLINE", "V_NONMONOTONIC", "V_ERRORED",
    "V_SURVIVORSHIP",
    "VERDICT_ORDER", "FATAL_VERDICTS", "SUSPECT_VERDICTS", "ROW_WIDE_VERDICTS",
    "STATUS_MEASURED", "STATUS_KEEP", "STATUS_DISCARD", "STATUS_CRASH",
    "STATUS_SUSPECT", "STATUS_VOID", "STATUS_VOCAB",
    "NA",
]

NA = "na"

# ---------------------------------------------------------------------------
# Tunable constants (contract sections 3 and 4). Overridable two ways, in order:
#   1. the environment variable of the same name
#   2. reassigning the module attribute (tests, callers)
# Reads happen at CALL time, so exporting AHL_MIN_TOKENS=4096 before invoking
# bench.sh changes the verdicts for that run.
# ---------------------------------------------------------------------------
AHL_MIN_DATA = 5            # successful < this -> no_data (fatal). MUST NOT MOVE: this is
                            # what catches contract section 0 defect (a), the 2-request level.
AHL_MIN_TOKENS = 2048       # successful * mean_output_tokens < this -> low_sample
AHL_MIN_SUCCESSFUL = 20     # request-count CEILING of the low_sample floor; the effective
                            # floor is max(AHL_MIN_DATA, min(AHL_MIN_SUCCESSFUL, 4*level))
AHL_DROP_TOL = 0.10         # an ADJACENT higher level this far below its predecessor -> nonmonotonic
AHL_ERR_TOL = 0.10          # errored / (successful+errored) > this -> errored
AHL_ROOFLINE_SAFETY = 3.0   # SAFETY multiplier on the bandwidth roofline
AHL_MIN_MODEL_GB = 1.0      # fallback bytes-per-token (GB) when the model size is unknown.
                            # Stays 1.0: deriving bytes/token from checkpoint size voids
                            # healthy rows (MoE active experts, vision towers) -- A5/A6.


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
V_SURVIVORSHIP = "survivorship"

# Emission order: the contract's section 3 table, with `survivorship` appended.
VERDICT_ORDER: tuple[str, ...] = (
    V_NO_DATA, V_LOW_SAMPLE, V_OVER_ROOFLINE, V_NONMONOTONIC, V_ERRORED, V_SURVIVORSHIP,
)
FATAL_VERDICTS = frozenset({V_NO_DATA, V_OVER_ROOFLINE})
SUSPECT_VERDICTS = frozenset({V_LOW_SAMPLE, V_NONMONOTONIC, V_ERRORED, V_SURVIVORSHIP})
# Verdicts that describe the ROW, not one level -- these stay bare (untagged).
ROW_WIDE_VERDICTS = frozenset({V_OK, V_NONMONOTONIC})

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
# Level-tagged verdict tokens (amendment 3):  low_sample@c1, no_data@c32
# ---------------------------------------------------------------------------
_TAGGED = re.compile(r"^([a-z_]+)@c(\d+)$")


def tag_verdict(base: str, level=None) -> str:
    """`low_sample` + level 1 -> `low_sample@c1`. Row-wide verdicts are never tagged."""
    if level is None or base in ROW_WIDE_VERDICTS:
        return base
    return "%s@c%d" % (base, int(level))


def split_verdict(token: str):
    """`low_sample@c1` -> ("low_sample", 1); `nonmonotonic` -> ("nonmonotonic", None).

    The one helper A4/A7 should use — do not hand-roll a splitter.
    """
    tok = (token or "").strip()
    m = _TAGGED.match(tok)
    if m:
        return m.group(1), int(m.group(2))
    return tok, None


def verdict_base(token: str) -> str:
    return split_verdict(token)[0]


def verdict_level(token: str) -> Optional[int]:
    return split_verdict(token)[1]


def _verdict_sort_key(token: str):
    base, lvl = split_verdict(token)
    try:
        rank = VERDICT_ORDER.index(base)
    except ValueError:
        rank = len(VERDICT_ORDER)
    return (rank, -1 if lvl is None else lvl, base)


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
    `tps` is `.benchmarks[0].metrics.output_tokens_per_second.successful.mean`.
    `out_tokens` is `.benchmarks[0].metrics.output_token_count.successful.mean` — the mean
    output tokens per SUCCESSFUL request, which is what the token-budget low_sample rule
    needs. Both are None when absent or non-finite.

    `missing` and `out_tokens` are trailing fields WITH DEFAULTS, so the 4-positional
    construction named in the original API spec -- LevelCounts(41, 0, 0, 12.3) -- still
    works. `missing` marks a level that WAS run but whose json is missing/unparseable: the
    contract's `no_data`, distinguished from a genuine zero by `c<N>:na` in `req_counts`.
    """

    ok: int = 0
    incomplete: int = 0
    errored: int = 0
    tps: Optional[float] = None
    missing: bool = False
    out_tokens: Optional[float] = None

    @property
    def total(self) -> int:
        return self.ok + self.incomplete + self.errored

    @property
    def token_budget(self) -> Optional[float]:
        """successful * mean_output_tokens, or None when the mean is unknown."""
        if self.out_tokens is None or not math.isfinite(self.out_tokens) or self.out_tokens <= 0:
            return None
        return self.ok * self.out_tokens


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


def _mean(metrics: Mapping, metric: str, kind: str = "successful") -> Optional[float]:
    node = metrics.get(metric)
    if not isinstance(node, Mapping):
        return None
    sub = node.get(kind)
    if not isinstance(sub, Mapping):
        return None
    return _finite(sub.get("mean"))


def parse_level_json(path) -> LevelCounts:
    """Read one GuideLLM per-level bundle. Raises LevelParseError if it is not usable.

    Field paths verified against all 693 retained bundles on node gb10-1988a9714b4e
    (GuideLLM 0.6.0): every one has exactly one entry in `benchmarks[]` and all of
    request_concurrency.{successful,incomplete,errored}.count,
    output_tokens_per_second.successful.mean and output_token_count.successful.mean present.

    NOTE a trap for other readers: output_tokens_per_second.successful.`count` is a TOKEN
    count (43055 on a 171-request level), not a request count. Request counts come only
    from request_concurrency.
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

    return LevelCounts(
        ok=ok, incomplete=incomplete, errored=errored,
        tps=_mean(metrics, "output_tokens_per_second"),
        out_tokens=_mean(metrics, "output_token_count"),
    )


_LEVEL_FILE = re.compile(r"^level_c(\d+)\.json$")


def _cell_published(value) -> bool:
    """Did the journal publish a cell for this level? `hang`/`crash` count as published
    (amendment 4: hung levels are SCORED); `na`/empty/None do not."""
    if value is None:
        return False
    s = str(value).strip().lower()
    return s not in ("", NA, "none", "null")



def level_meta(path) -> dict:
    """Run metadata recorded alongside the counts in one level bundle.

    The knobs a run was executed with are journalled by GuideLLM itself, so the historical
    `knobs` column can be reconstructed from a retained bundle rather than guessed. Returns
    {} for anything unreadable -- callers treat a missing knob as `na`, never as a default.

    Paths (GuideLLM 0.6.0): `.args.max_seconds`, `.args.random_seed`, `.metadata.guidellm_version`,
    and prompt/output token targets parsed out of the `.args.data` synthetic spec string.
    """
    try:
        with Path(path).open("r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    if not isinstance(doc, Mapping):
        return {}
    args = doc.get("args") if isinstance(doc.get("args"), Mapping) else {}
    meta = doc.get("metadata") if isinstance(doc.get("metadata"), Mapping) else {}

    out = {
        "max_seconds": args.get("max_seconds"),
        "seed": args.get("random_seed"),
        "guidellm_version": meta.get("guidellm_version"),
        "prompt_tokens": None,
        "output_tokens": None,
    }
    data = args.get("data")
    if isinstance(data, (list, tuple)) and data:
        data = data[0]
    if isinstance(data, str):
        for field in ("prompt_tokens", "output_tokens"):
            m = re.search(r"(?:^|,)%s=(\d+)" % field, data)
            if m:
                out[field] = int(m.group(1))
    return {k: v for k, v in out.items() if v is not None}


def scan_bundle(bundle_dir, levels: Iterable, tps: Optional[Mapping] = None,
                discover: bool = True) -> dict:
    """Read `level_c<N>.json` for every RUN level of one benchmark row.

    Amendment 4 — a level counts as RUN if the journal published a cell for it OR a bundle
    file exists for it (the union). So:
      * a level that hung (cell `hang`, no json) IS scored, as `no_data@c<N>` — which is
        what makes a crash row say WHICH level wedged;
      * a level that was never attempted (cell `na`, no json) is dropped, never scored as
        a zero;
      * a bundle file present for a level the journal never mentions is picked up
        (`discover=True`), which surfaces hand-corrected rows.
    When `tps` is None the caller has supplied no journal information, so `levels` is taken
    at face value and is authoritative (contract confirmation 8).

    `tps` maps level -> the RAW results.tsv cell (float, or a string such as `151.5`,
    `na`, `hang`). A numerically parseable cell also overrides the tok/s read from the
    bundle, because the journal cell is what a reader will actually cite.
    """
    bundle = Path(bundle_dir)

    on_disk: set = set()
    if discover and bundle.is_dir():
        for p in bundle.iterdir():
            m = _LEVEL_FILE.match(p.name)
            if m:
                on_disk.add(int(m.group(1)))

    candidates = set(int(x) for x in levels) | on_disk
    out: dict = {}
    for lvl in sorted(candidates):
        try:
            counts = parse_level_json(bundle / ("level_c%d.json" % lvl))
        except LevelParseError:
            counts = LevelCounts(missing=True)

        if tps is not None:
            published = _cell_published(tps.get(lvl))
            if counts.missing and not published:
                continue                      # never attempted -- not a zero, not scored
            override = _finite(parse_tps(tps.get(lvl)))
            if override is not None:
                counts = LevelCounts(counts.ok, counts.incomplete, counts.errored,
                                     override, counts.missing, counts.out_tokens)
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
    sound bound. `safety` defaults to AHL_ROOFLINE_SAFETY (3.0 -- MTP accepted length
    reaches 2.69 on this node, so 2.0 would fatally void a legitimate spec-decode config).
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
def min_requests_for_level(level) -> int:
    """The request-count floor of the low_sample rule for one concurrency level:

        max(AHL_MIN_DATA, min(AHL_MIN_SUCCESSFUL, 4 * level))

    A c1 sentinel physically cannot produce 20 requests inside a 180 s stage, so a flat
    floor of 20 declared 55% of this node's historical levels suspect. The token-budget
    clause below is the primary precision test; this clause is the backstop.
    """
    min_data = _cfg("AHL_MIN_DATA", int)
    cap = _cfg("AHL_MIN_SUCCESSFUL", int)
    return max(min_data, min(cap, 4 * int(level)))


def verdicts(levels: Mapping, ceiling_fn: Optional[Callable] = None) -> list:
    """The contract section 3 verdict tokens for one results.tsv row.

    `levels` maps concurrency -> LevelCounts for the levels that were RUN (see scan_bundle
    for what "run" means). A key mapped to None -- or to anything that is not a LevelCounts
    -- is treated as UNRUN and skipped entirely: an unrun level is never a zero.
    `ceiling_fn` is None when the roofline check must be skipped (no mem_bw for the node).

    Per-level verdicts come back level-tagged (`low_sample@c1`); the row-wide
    `nonmonotonic` stays bare. Use split_verdict() to take them apart.
    """
    min_data = _cfg("AHL_MIN_DATA", int)
    min_tokens = _cfg("AHL_MIN_TOKENS", float)
    drop_tol = _cfg("AHL_DROP_TOL", float)
    err_tol = _cfg("AHL_ERR_TOL", float)

    run = {int(k): v for k, v in (levels or {}).items() if isinstance(v, LevelCounts)}
    found: set = set()

    for lvl in sorted(run):
        c = run[lvl]

        # no_data and low_sample are mutually exclusive PER LEVEL -- report the more severe.
        if c.missing or c.ok < min_data:
            found.add(tag_verdict(V_NO_DATA, lvl))
        else:
            budget = c.token_budget
            thin_tokens = budget is not None and budget < min_tokens
            thin_requests = c.ok < min_requests_for_level(lvl)
            if thin_tokens or thin_requests:
                found.add(tag_verdict(V_LOW_SAMPLE, lvl))

        denom = c.ok + c.errored
        if denom > 0 and (c.errored / denom) > err_tol:
            found.add(tag_verdict(V_ERRORED, lvl))

        # survivorship: GuideLLM's successful.mean drops the requests still in flight, and
        # those are the SLOW ones -- so a level where at least as many requests were
        # dropped as completed reports the mean of its faster half.
        if not c.missing and c.incomplete >= c.ok:
            found.add(tag_verdict(V_SURVIVORSHIP, lvl))

        if ceiling_fn is not None and c.tps is not None and not c.missing:
            cap = ceiling_fn(lvl)
            if cap is not None and math.isfinite(cap) and c.tps > cap:
                found.add(tag_verdict(V_OVER_ROOFLINE, lvl))

    # nonmonotonic (row-wide, ADJACENT-ONLY): each run level vs the previous run level.
    # Pairwise-all would flag the gentle high-concurrency decay that is legitimate on a
    # bandwidth-bound box.
    curve = [(lvl, run[lvl].tps) for lvl in sorted(run)
             if run[lvl].tps is not None and not run[lvl].missing]
    for (_lo, t_lo), (_hi, t_hi) in zip(curve, curve[1:]):
        if t_lo > 0 and t_hi < t_lo * (1.0 - drop_tol):
            found.add(V_NONMONOTONIC)
            break

    return sorted(found, key=_verdict_sort_key) or [V_OK]


def format_validity(verds: Iterable) -> str:
    """`ok`, or the `+`-joined verdict tokens in contract order then level order."""
    seen = {v for v in (verds or []) if v and v != V_OK}
    return "+".join(sorted(seen, key=_verdict_sort_key)) if seen else V_OK


def parse_validity(s: Optional[str]) -> list:
    """Inverse of format_validity, as raw (possibly level-tagged) tokens.
    `ok`/`na`/empty -> ["ok"]."""
    if not s:
        return [V_OK]
    s = s.strip()
    if s in ("", NA, V_OK):
        return [V_OK]
    return [tok for tok in (p.strip() for p in s.split("+")) if tok]


def parse_validity_pairs(s: Optional[str]) -> list:
    """format_validity string -> [(base, level|None), ...]. For consumers that gate on the
    level they actually cite, e.g. promote.sh ignoring `low_sample@c1` while honouring
    `low_sample@c16`."""
    return [split_verdict(tok) for tok in parse_validity(s)]


# ---------------------------------------------------------------------------
# Section 5 -- enforcement
# ---------------------------------------------------------------------------
def status_floor(verds: Iterable) -> str:
    """`void` (any fatal verdict) / `suspect` (any suspect verdict) / `ok`.
    Accepts level-tagged or bare tokens."""
    bases = {verdict_base(v) for v in (verds or []) if v}
    if bases & FATAL_VERDICTS:
        return "void"
    if bases & SUSPECT_VERDICTS:
        return "suspect"
    return "ok"


def apply_status(current_status: Optional[str], floor: str) -> str:
    """Contract section 5 precedence. A crash ALWAYS wins: an already-`crash` row keeps
    status=crash and records its verdict in `validity` instead (now level-tagged, so the
    row says which level wedged). Otherwise a fatal floor forces `void`, a suspect floor
    forces `suspect`, and an `ok` floor leaves the caller's status untouched."""
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
# Triple order is ok/incomplete/errored (confirmed). `c<N>:na` = the level was run but its
# json is missing/unparseable.
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
    """Inverse of format_req_counts. Counts round-trip exactly; `tps` and `out_tokens` are
    not carried by the encoding and always come back None."""
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
# Section 2 -- knobs encoding: levels=1|16,max_s=180,seed=42,...
# Amendment 6: list values join with `|`, NEVER a comma, so no value can contain the pair
# separator and a naive split(",") is always correct. The lookahead split below is kept as
# belt-and-braces for hand-edited or legacy `levels=1,16` strings.
# ---------------------------------------------------------------------------
_KNOB_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_.\-]*$")
_KNOB_SPLIT = re.compile(r",(?=[A-Za-z_][A-Za-z0-9_.\-]*=)")
_LIST_SEP = "|"


def _knob_value(v) -> str:
    if v is None:
        return NA
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        s = repr(round(v, 6))
        if s.endswith(".0"):
            s = s[:-2]
    elif isinstance(v, (list, tuple, set, frozenset)):
        items = sorted(v) if isinstance(v, (set, frozenset)) else list(v)
        s = _LIST_SEP.join(_knob_value(x) for x in items)
    else:
        s = str(v)
    s = s.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
    # A comma inside a value would break the naive split(",") the format now guarantees.
    s = s.replace(",", _LIST_SEP)
    return s if s else NA


def format_knobs(knobs=None, **kw) -> str:
    """`k=v` comma-joined, in the order the kwargs were given. Empty -> `na`.
    List values join with `|` (`levels=1|16`); commas inside a value are rewritten to `|`
    so split(",") is always safe. Tabs/newlines are stripped so a value can never break
    the TSV."""
    if knobs is not None:
        # Callers hand this a mapping (the migration, the audit, the test suite) as often as
        # kwargs; accept either rather than making every consumer spread a dict it already has.
        merged = dict(knobs)
        merged.update(kw)
        kw = merged
    parts = []
    for k, v in kw.items():
        if not _KNOB_KEY.match(k):
            raise ValueError("bad knob key: %r" % k)
        parts.append("%s=%s" % (k, _knob_value(v)))
    return ",".join(parts) if parts else NA


def parse_knobs(s: Optional[str]) -> dict:
    """Inverse of format_knobs. Values stay strings; a `|`-joined list stays joined (split
    it yourself on `|` if you want the elements). The lookahead split also tolerates a
    legacy `levels=1,16` written before amendment 6."""
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

    # Raw cells are kept as STRINGS: scan_bundle needs to tell `hang` (published -> the
    # level was run and is scored) from `na` (never attempted -> dropped).
    cells: dict = {}
    if args.tps:
        raw = [c.strip() for c in str(args.tps).split(",")]
        if len(raw) == len(levels) and len(raw) != len(LEVEL_COLUMNS):
            for lvl, cell in zip(levels, raw):          # convenience: one per RUN level
                cells[lvl] = cell
        else:
            for idx, cell in enumerate(raw[:len(LEVEL_COLUMNS)]):   # the 5 fixed columns
                cells[LEVEL_COLUMNS[idx]] = cell

    counts = scan_bundle(args.bundle, levels, cells if cells else None)
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


def _cmd_split(args) -> int:
    base, lvl = split_verdict(args.token)
    print("%s\t%s" % (base, NA if lvl is None else lvl))
    return 0



# ── Public composite entry point ──────────────────────────────────────────────
# A2/A5 (via the shim), A7's five near-duplicate row classifiers and the acceptance suite
# all want the same thing: "given a bundle and the levels that ran, tell me the verdict,
# the counts, and the status this row should carry". Expose it once rather than five times.
EXIT_OK = 0
EXIT_CRASH = 3        # the box broke
EXIT_INVALID = 4      # the row is written but not citable (contract §5)

# Public aliases. The names on the right are canonical; these are the shorter spellings
# consumers reach for first.
COLUMNS = RESULTS_COLS
STATUSES = STATUS_VOCAB
SAFETY = AHL_ROOFLINE_SAFETY


@dataclass(frozen=True)
class BundleAssessment:
    """What one benchmark row's evidence says about itself."""
    validity: str          # `+`-joined verdict tokens, or `ok`/`na`
    req_counts: str        # `c1:41/0/0;c16:118/4/0`, or `na`
    status_floor: str      # ok | suspect | void
    status: str            # the status the row should carry, after §5 precedence
    levels: dict           # level -> LevelCounts, for callers that want the detail

    @property
    def verdicts(self) -> list:
        return parse_validity(self.validity)


def assess_bundle(bundle_dir, levels, tps=None, node_profile=None, status=None,
                  bytes_per_token_gb=None) -> BundleAssessment:
    """Assess one run's bundle end to end (contract §3/§4/§5).

    `levels` is the list of levels that were RUN — authoritative over whatever files happen
    to be in the directory, so a stale level_c8.json from a previous shape is ignored and a
    level whose json vanished is still judged (`no_data`).

    `node_profile` may be a path or an already-loaded mapping; without a readable
    `gpu.mem_bw_gbs` the roofline check is skipped, never guessed.
    """
    # discover=False: the caller's run-level list is authoritative (contract v1.1 §3), so a
    # stale level_c8.json from a previous shape in the same bundle dir is never scored.
    # The audit/migration path opts into discovery deliberately; a live bench never should.
    scanned = scan_bundle(bundle_dir, levels, tps, discover=False)
    mem_bw = None
    if node_profile is not None:
        if isinstance(node_profile, Mapping):
            gpu = node_profile.get("gpu")
            raw = gpu.get("mem_bw_gbs") if isinstance(gpu, Mapping) else None
            mem_bw = _finite(raw) if raw is not None else None
        else:
            mem_bw = read_mem_bw(node_profile)
    ceiling_fn = make_ceiling_fn(mem_bw, bytes_per_token_gb) if mem_bw else None

    verds = verdicts(scanned, ceiling_fn)
    floor = status_floor(verds)
    return BundleAssessment(
        validity=format_validity(verds),
        req_counts=format_req_counts(scanned),
        status_floor=floor,
        status=apply_status(status, floor),
        levels=dict(scanned),
    )


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

    sp = sub.add_parser("split", help="split a verdict token into base + level")
    sp.add_argument("token")
    sp.set_defaults(func=_cmd_split)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
