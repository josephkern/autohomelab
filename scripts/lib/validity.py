#!/usr/bin/env python3
"""Measurement-validity rules — the SINGLE source of truth for docs/validity-contract.md.

Nothing else in this repo may re-implement these rules. `scripts/lib/validity.sh` is a thin
bash shim that shells out to this module; the bench scripts, aggregate.py, promote.sh and
run_experiment.sh all consume the schema and the verdicts from here.

Stdlib only, on purpose: this module must be importable and runnable in any context that can
run python, including from inside a bash shim during a benchmark.

Contract v1.1 (amendment batch 1) is folded in:
  1. per-level verdict tokens carry their level: `low_sample@c1`, `no_data@c32`.
  2. hung levels are SCORED, not skipped; a level is "run" if the journal published a cell
     OR a bundle file exists.
  3. `nonmonotonic` is ADJACENT-ONLY.
  4. knobs list values join with `|`, never a comma.
  5. AHL_ROOFLINE_SAFETY 2.0 -> 3.0 (MTP accepted length reaches 2.69 on this node).

Contract v1.2 (2026-08-19, four independent verifiers) is folded in on top:
  A1. the token-budget clause is GONE. `low_sample` is solely a request-count floor. The
      clause fired alone on 3 of 693 bundles, all three the most reproducible bracket on
      this node (CV 0.59-0.70%), and it APPROVED 10 of the 15 genuinely starved levels
      because a coder completion carries ~1000 tokens (3 requests clear a 2048 budget).
  A2. `survivorship` fires on MAJORITY discard: `ok > 0 and incomplete > ok`, i.e. the
      published mean is an average over a minority of the work started. Two earlier forms
      were wrong and the rule carries the measurements: v1.1 used this condition but
      justified it as a general bias detector (it cannot fire below 50% discard), and
      v1.2's first form `incomplete > level` was unsatisfiable — GuideLLM bounds in-flight
      by the level — so it fired ZERO times on 690 levels. The systemic 30-48% coder
      discard is a METHODOLOGY finding (lab notes + audit), not a per-row verdict: at a
      30% threshold it would flag 19 of 23 coder rows.
  A3. new FATAL `no_output`: successful > 0 but tok/s null / non-finite / <= 0. There was
      a ceiling on throughput and no floor (NemotronH emits zero tokens under think-off).
  A4. `errored` ESCALATES: > AHL_ERR_FATAL (50%) is fatal (`errored_fatal`), 10-50% stays
      suspect. A dead endpoint (107,589 errors, 17 successes) used to score the same as a
      level with 11% errors.
  A5. `na` is NEVER `ok`. verdicts({}) -> `na`; parse_validity("na"/"") -> ["na"]; an
      unevaluable bundle floors at `suspect`, never at `ok`.
  A10. the CLI and assess_bundle are the SAME path: the caller's run-level list is
      authoritative, and only the audit/migration path opts into discovery, explicitly.
      `SAFETY` is resolved on attribute access, so the documented override path works.

Contract v1.3 (2026-08-20) folds in one more, on the SECTION 6 vocabulary:
  V1. `keep` is RETIRED (0 of 317 rows; a keep verdict is per-CONFIG on a median of N, while
      `status` is per-ROW and is written before that comparison exists). It is refused, not
      merely undocumented: check_status()/apply_status() raise on it.
  V2. `discard` is RETAINED and redefined as an ORCHESTRATOR ADJUDICATION under section 7,
      applied to the journal after the fact and signed `adjudicated@YYYYMMDD who: reason` in
      `notes`. See the STATUS_VOCAB block for the evidence behind both halves.

CLI:
    python3 scripts/lib/validity.py check --bundle DIR --levels 1,16 \
        --tps 41.2,na,na,151.5,na [--node-profile P] [--model-gb G] [--discover]
prints one JSON object: {"validity": ..., "req_counts": ..., "status_floor": ...}

    python3 scripts/lib/validity.py status --status discard [--notes "…"]   # 0 ok, 2 refused
    python3 scripts/lib/validity.py status --tsv results/*/*/*/results.tsv  # 0 clean, 4 offenders
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
    "assess_bundle", "BundleAssessment", "COLUMNS", "LEVELS", "STATUSES", "SAFETY",
    "EXIT_OK", "EXIT_CRASH", "EXIT_INVALID",
    "LevelCounts", "LevelParseError", "parse_level_json", "scan_bundle",
    "verdicts", "format_validity", "parse_validity", "parse_validity_pairs",
    "split_verdict", "verdict_base", "verdict_level", "tag_verdict",
    "status_floor", "apply_status",
    "format_req_counts", "parse_req_counts", "format_knobs", "parse_knobs",
    "ceiling", "make_ceiling_fn", "read_mem_bw", "parse_tps", "min_requests_for_level",
    "AHL_MIN_DATA", "AHL_MIN_SUCCESSFUL", "AHL_DROP_TOL", "AHL_ERR_TOL", "AHL_ERR_FATAL",
    "AHL_DISCARD_TOL", "AHL_ROOFLINE_SAFETY", "AHL_MIN_MODEL_GB",
    "V_OK", "V_NA", "V_NO_DATA", "V_LOW_SAMPLE", "V_OVER_ROOFLINE", "V_NO_OUTPUT",
    "V_NONMONOTONIC", "V_ERRORED", "V_ERRORED_FATAL", "V_SURVIVORSHIP",
    "V_INCOMPLETE_RUN", "add_verdict",
    "VERDICT_ORDER", "FATAL_VERDICTS", "SUSPECT_VERDICTS", "UNEVALUATED_VERDICTS",
    "ROW_WIDE_VERDICTS",
    "STATUS_MEASURED", "STATUS_DISCARD", "STATUS_CRASH",
    "STATUS_SUSPECT", "STATUS_VOID", "STATUS_VOCAB", "STATUS_RETIRED",
    "STATUS_ADJUDICATED", "ADJUDICATION_RE", "ADJUDICATION_MIN_REASON",
    "parse_adjudication", "is_adjudicated", "check_status", "EXIT_USAGE",
    "NA",
]

NA = "na"

# ---------------------------------------------------------------------------
# Tunable constants (contract sections 3 and 4). Overridable two ways, in order:
#   1. the environment variable of the same name
#   2. reassigning the module attribute (tests, callers)
# Reads happen at CALL time, so exporting AHL_MIN_DATA=10 before invoking
# bench.sh changes the verdicts for that run.
# ---------------------------------------------------------------------------
AHL_MIN_DATA = 5            # successful < this -> no_data (fatal). MUST NOT MOVE: this is
                            # what catches contract section 0 defect (a), the 2-request level.
AHL_MIN_SUCCESSFUL = 20     # request-count CEILING of the low_sample floor; the effective
                            # floor is max(AHL_MIN_DATA, min(AHL_MIN_SUCCESSFUL, 4*level))
AHL_DROP_TOL = 0.10         # an ADJACENT higher level this far below its predecessor -> nonmonotonic
AHL_ERR_TOL = 0.10          # errored / (successful+errored) > this -> errored (suspect)
AHL_ERR_FATAL = 0.50        # ... and > this -> errored_fatal (A4). A dead endpoint answers
                            # every request instantly and mostly with an error.
AHL_DISCARD_TOL = 0.30      # RETIRED 20260819: the discard-fraction form flagged 83% of
                            # coder rows (methodology, not per-row defect). Kept for the audit's
                            # reporting only; the survivorship RULE is majority-discard.
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
V_NA = NA                   # "the rules could not be evaluated" -- A5: never `ok`.
V_NO_DATA = "no_data"
V_LOW_SAMPLE = "low_sample"
V_OVER_ROOFLINE = "over_roofline"
V_NO_OUTPUT = "no_output"       # A3: the FLOOR under the roofline's ceiling.
V_NONMONOTONIC = "nonmonotonic"
# A sweep that was cut short: real numbers for the levels that landed, but the run as a whole was
# never completed. ROW-WIDE and untagged on purpose -- "this run was interrupted" is a property of
# the run, not of one concurrency level, and a row-wide token is the only kind that survives the
# level-scoped reading a promotion gate uses. SUSPECT, not fatal: the completed levels ARE data
# (voiding them would be the mirror-image lie), but they are not citable until a human adjudicates
# under contract section 7. A fatal verdict still outranks it via status_floor.
V_INCOMPLETE_RUN = "incomplete_run"
V_ERRORED = "errored"
V_ERRORED_FATAL = "errored_fatal"   # A4: the >50% band of `errored`.
V_SURVIVORSHIP = "survivorship"

# Emission order: the contract's section 3 table, with the v1.1/v1.2 additions slotted in
# beside the rule they escalate.
VERDICT_ORDER: tuple[str, ...] = (
    V_NO_DATA, V_LOW_SAMPLE, V_OVER_ROOFLINE, V_NO_OUTPUT, V_INCOMPLETE_RUN, V_NONMONOTONIC,
    V_ERRORED_FATAL, V_ERRORED, V_SURVIVORSHIP,
)
FATAL_VERDICTS = frozenset({V_NO_DATA, V_OVER_ROOFLINE, V_NO_OUTPUT, V_ERRORED_FATAL})
SUSPECT_VERDICTS = frozenset({V_LOW_SAMPLE, V_NONMONOTONIC, V_ERRORED, V_SURVIVORSHIP,
                              V_INCOMPLETE_RUN})
# `na` is neither: it is the ABSENCE of a verdict. It floors at `suspect` (A5) because an
# unevaluable row is not citable, but it is not evidence of a defect the way the others are.
UNEVALUATED_VERDICTS = frozenset({V_NA})
# Verdicts that describe the ROW, not one level -- these stay bare (untagged).
ROW_WIDE_VERDICTS = frozenset({V_OK, V_NA, V_NONMONOTONIC, V_INCOMPLETE_RUN})

# ---------------------------------------------------------------------------
# Section 6 status vocabulary -- v1.3 (2026-08-20), FIVE words. `keep` is RETIRED.
#
# `keep` was never written: 0 of 317 rows across 15 campaigns. It failed on both axes a row-level
# status has to satisfy:
#   * WRONG GRAIN. A keep verdict is a statement about a CONFIG, decided on the median of N=3
#     benches. `status` is a property of ONE row. There is no row that is "the kept one".
#   * WRONG TIME. `bench.sh` writes each row as that row finishes, and section 7 forbids rewriting
#     a published row afterwards -- so at the only moment the column can be written, the
#     comparison that would justify `keep` has not happened yet.
# The keep/discard decision lives where it always actually lived: `run_experiment.sh`'s MEDIAN
# line, `tune_status.py`'s ranking, and the campaign `logbook.md`.
#
# `discard` is RETAINED, and redefined as what the record shows it has always been: an
# ORCHESTRATOR ADJUDICATION under section 7, applied to the journal AFTER the fact. It is never
# set at bench time -- `bench_ds4.sh` and `bench_llamacpp.sh` hard-code `status="measured"` and
# never read `$STATUS` at all, and all six `discard` rows in the corpus were applied by later
# adjudication commits.
#
# It is retained because there is a class of row that only a human can fault, and that class is
# non-empty: run `20260809-183024-chat` (cfg 653a8d9c, the FF711 `NP=32` bench) classifies
# **valid at c16 -- the tuning objective** -- carrying only `survivorship@c32`. Nothing in
# `validity` can see that `NP=32` x `CTX_PER_SLOT=12288` over-committed unified memory into swap,
# because swap leaves no trace in a GuideLLM level json. Contamination, confounded design and
# swap are refutations the invariants cannot reach, and `discard` is the only place to record one.
#
# Because such a row is rejected on a human's authority alone, the authority must be legible: a
# hand-set `discard` MUST carry `adjudicated@YYYYMMDD who: reason` in `notes` (see
# ADJUDICATION_RE / check_status below), so every discard in the journal is dated, attributed and
# greppable instead of resting on unattributed prose.
# ---------------------------------------------------------------------------
STATUS_MEASURED = "measured"
STATUS_DISCARD = "discard"
STATUS_CRASH = "crash"
STATUS_SUSPECT = "suspect"
STATUS_VOID = "void"
STATUS_VOCAB = (
    STATUS_MEASURED, STATUS_DISCARD, STATUS_CRASH, STATUS_SUSPECT, STATUS_VOID,
)
# Words that WERE in the vocabulary and are not any more, with why. Kept so a consumer that meets
# one in an old script or an old note gets an explanation, not a bare "unknown status".
STATUS_RETIRED = {
    "keep": "retired v1.3 (2026-08-20): never written (0 of 317 rows). A keep verdict is "
            "per-CONFIG on a median of N, while `status` is per-ROW and is written before that "
            "comparison exists. The decision lives in run_experiment.sh's MEDIAN line, "
            "tune_status.py's ranking and the campaign logbook.",
}
# Statuses a human/orchestrator sets by hand, which therefore require an adjudication stamp in
# `notes`. `void`/`suspect` are computed by the invariants and `crash` by the watchdog;
# `measured` is the default. None of those is a human judgement, so none needs a signature.
STATUS_ADJUDICATED = frozenset({STATUS_DISCARD})

# `adjudicated@YYYYMMDD who: reason` -- the signature a hand-set status carries in `notes`.
# Deliberately the same shape as promote.sh's AHL_PROMOTE_OVERRIDE rule: an adjudication is an
# argument, not a flag, so the reason has a minimum length and a bare word does not qualify.
ADJUDICATION_MIN_REASON = 12
ADJUDICATION_RE = re.compile(
    r"adjudicated@(?P<date>\d{8})\s+(?P<who>[^:;\t]{1,64}?)\s*:\s*(?P<reason>\S[^\t]*)")


def parse_adjudication(notes: Optional[str]):
    """`notes` -> (date, who, reason) for the first well-formed stamp, else None.

    Well-formed means: a plausible `YYYYMMDD` (year 2000-2999, month 01-12, day 01-31), a
    non-empty attribution, and a reason of at least ADJUDICATION_MIN_REASON characters. A stamp
    that parses but says nothing (`adjudicated@20260820 jk: x`) is not a signature.
    """
    for m in ADJUDICATION_RE.finditer(notes or ""):
        date, who, reason = m.group("date"), m.group("who").strip(), m.group("reason").strip()
        year, month, day = int(date[:4]), int(date[4:6]), int(date[6:])
        if not (2000 <= year <= 2999 and 1 <= month <= 12 and 1 <= day <= 31):
            continue
        if not who or len(reason) < ADJUDICATION_MIN_REASON:
            continue
        return date, who, reason
    return None


def is_adjudicated(notes: Optional[str]) -> bool:
    """Does `notes` carry a well-formed `adjudicated@YYYYMMDD who: reason` stamp?"""
    return parse_adjudication(notes) is not None


def check_status(status: Optional[str], notes: Optional[str] = None) -> str:
    """Return `status` if section 6 admits it, else raise ValueError explaining why not.

    Two rules, both section 6 / section 7:
      * the word must be in STATUS_VOCAB -- `keep` gets its retirement notice by name;
      * a status in STATUS_ADJUDICATED (`discard`) must carry an adjudication stamp in `notes`,
        because it is a rejection the invariants did not make. `notes=None` skips that half, for
        callers validating a word rather than a row.
    """
    s = (status or "").strip()
    if s in STATUS_RETIRED:
        raise ValueError("status %r is retired -- %s" % (s, STATUS_RETIRED[s]))
    if s not in STATUS_VOCAB:
        raise ValueError("status %r is not in the section 6 vocabulary (%s)"
                         % (s, " ".join(STATUS_VOCAB)))
    if notes is not None and s in STATUS_ADJUDICATED and not is_adjudicated(notes):
        raise ValueError(
            "status %r is an orchestrator adjudication (section 7) and must carry "
            "`adjudicated@YYYYMMDD who: reason` (reason >= %d chars) in `notes`; got: %r"
            % (s, ADJUDICATION_MIN_REASON, (notes or "")[:200]))
    return s

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
    output tokens per SUCCESSFUL request. Both are None when absent or non-finite. NOTE
    (A1): `out_tokens`/`token_budget` no longer decide any verdict — the token-budget
    clause of `low_sample` is deleted. They are kept because they are the evidence a reader
    needs to interpret a thin level, and because the audit reports them.

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
        """successful * mean_output_tokens, or None when the mean is unknown.

        INFORMATIONAL ONLY since v1.2/A1 — no rule reads it. Do not resurrect it as a
        threshold without re-running it over the corpus: its correlation with measured
        reproducibility on this node is r = -0.006.
        """
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
                discover: bool = False) -> dict:
    """Read `level_c<N>.json` for every RUN level of one benchmark row.

    Amendment 4 — a level counts as RUN if the journal published a cell for it OR a bundle
    file exists for it (the union). So:
      * a level that hung (cell `hang`, no json) IS scored, as `no_data@c<N>` — which is
        what makes a crash row say WHICH level wedged;
      * a level that was never attempted (cell `na`, no json) is dropped, never scored as
        a zero;
      * a bundle file present for a level the journal never mentions is picked up ONLY when
        the caller passes `discover=True` — the audit/migration path, which reconstructs a
        run-level list it does not own. A10: the default is now False everywhere, so the
        caller's run-level list is authoritative on the executed path exactly as §3 says.
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
    floor of 20 declared 55% of this node's historical levels suspect. Since A1 deleted the
    token-budget clause this IS the `low_sample` rule, not a backstop to it.
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

    A5: NO run levels at all -> `["na"]`, never `["ok"]`. "Nothing to check" and "everything
    checked out" are opposite claims and the column has to be able to tell them apart.
    """
    min_data = _cfg("AHL_MIN_DATA", int)
    drop_tol = _cfg("AHL_DROP_TOL", float)
    err_tol = _cfg("AHL_ERR_TOL", float)
    err_fatal = _cfg("AHL_ERR_FATAL", float)
    discard_tol = _cfg("AHL_DISCARD_TOL", float)

    run = {int(k): v for k, v in (levels or {}).items() if isinstance(v, LevelCounts)}
    if not run:
        return [V_NA]
    found: set = set()

    for lvl in sorted(run):
        c = run[lvl]

        # no_data and low_sample are mutually exclusive PER LEVEL -- report the more severe.
        if c.missing or c.ok < min_data:
            found.add(tag_verdict(V_NO_DATA, lvl))
        elif c.ok < min_requests_for_level(lvl):
            found.add(tag_verdict(V_LOW_SAMPLE, lvl))

        # A3 no_output: requests SUCCEEDED and produced no tokens. The roofline bounds this
        # metric from above; nothing bounded it from below, so a serve emitting empty
        # completions (NemotronH under think-off does exactly this) graded `ok` at 0 tok/s.
        if not c.missing and c.ok > 0:
            rate = _finite(c.tps)
            if rate is None or rate <= 0:
                found.add(tag_verdict(V_NO_OUTPUT, lvl))

        # A4 errored: two bands. Above 50% the endpoint is not serving, it is refusing, and
        # a mean over the survivors is not a measurement of anything.
        denom = c.ok + c.errored
        if denom > 0:
            err_rate = c.errored / denom
            if err_rate > err_fatal:
                found.add(tag_verdict(V_ERRORED_FATAL, lvl))
            elif err_rate > err_tol:
                found.add(tag_verdict(V_ERRORED, lvl))

        # survivorship (v1.2 A2, RE-ADJUDICATED 20260819 after measurement).
        # GuideLLM's successful.mean silently drops the requests still in flight, and those
        # are the SLOW ones, so the reported mean is the mean of the faster part. This rule
        # fires when a MAJORITY of the work started at a level was discarded: the published
        # number is then an average over a minority of the requests.
        #
        # History, kept because two adjudications went wrong here and the reasons matter.
        # v1.1 used `incomplete >= ok` but justified it as a general bias detector; a
        # verifier showed that is arithmetically `ok <= level` (the in-flight set at stage
        # end is ~level) and therefore cannot fire below a 50% discard rate, while the
        # justification cited 32.4%/46.2% regimes. v1.2 A2 then tried `incomplete > level`
        # to subtract that in-flight set -- but GuideLLM BOUNDS in-flight by the level, so
        # that condition is unsatisfiable and the rule fired ZERO times on 690 levels.
        # Measured row impact of the alternatives on this corpus (315 rows, 23 coder):
        # discard>30% flags 19/23 coder rows, >40% flags 13/23, >50% flags 10/23.
        # A verdict that fires on 83% of a shape is a statement about the METHODOLOGY, not
        # a per-row defect signal, and it is the flag-fatigue failure this layer must avoid.
        #
        # So the rule is deliberately a MAJORITY-DISCARD rule, and its limit is stated
        # rather than implied: it does NOT catch the systemic 30-48% discard that the coder
        # shape shows at high concurrency. That bias is real, it is a property of the
        # measurement method rather than of any single run, and it is recorded in the
        # AGENTS.md lab notes and research/review/AUDIT-measurement-validity.md instead of
        # being flagged 19 times per campaign. Never fires on an empty level.
        if not c.missing and c.ok > 0 and c.incomplete > c.ok:
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


def add_verdict(validity, *tokens) -> str:
    """Add verdict token(s) to an existing `validity` string, canonically.

    The callers are shell scripts recording a fact the RULES cannot compute -- that a run was
    interrupted. They must not hand-assemble the string: ordering, dedupe and the `ok`/`na`
    placeholders are the library's business (contract section 1), and a caller that got them
    subtly wrong would produce a verdict no consumer parses the way it intended.

    `ok` and `na` are placeholders meaning "nothing to say" and "could not be evaluated"; a real
    token replaces them rather than joining them.
    """
    have = [t for t in parse_validity(validity) if t not in (V_OK, V_NA)]
    for tok in tokens:
        base = verdict_base(tok)
        if base not in VERDICT_ORDER:
            raise ValueError("unknown verdict: %r" % tok)
        if base in ROW_WIDE_VERDICTS and tok != base:
            raise ValueError("%s is row-wide and must not be level-tagged: %r" % (base, tok))
        if tok not in have:
            have.append(tok)
    return format_validity(have) if have else V_OK


def format_validity(verds: Iterable) -> str:
    """`ok`, or the `+`-joined verdict tokens in contract order then level order.
    A bare `na` (nothing was evaluable) round-trips as `na`, not as `ok`."""
    seen = {v for v in (verds or []) if v and v != V_OK}
    return "+".join(sorted(seen, key=_verdict_sort_key)) if seen else V_OK


def parse_validity(s: Optional[str]) -> list:
    """Inverse of format_validity, as raw (possibly level-tagged) tokens.

    A5: `ok` -> ["ok"]; `na`, empty and None -> **["na"]**, never ["ok"]. §3 has said since
    v1.1 that `na` means "could not be evaluated"; returning ["ok"] for it made every
    consumer that parsed before checking wrong by construction — an unevaluable row read as
    citable. Empty/None land on `na` for the same reason: a missing column is not a pass.
    """
    if not s:
        return [V_NA]
    s = s.strip()
    if s == "" or s.lower() == NA:
        return [V_NA]
    if s == V_OK:
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
    """`void` (any fatal verdict) / `suspect` (any suspect verdict, or `na`) / `ok`.
    Accepts level-tagged or bare tokens.

    A5: an UNEVALUATED row (`na`, or an empty token list) floors at `suspect`. It is not
    `ok` — no invariant passed, none was run — and it is not `void` either, because nothing
    was refuted. `suspect` is exactly the contract's "not citable without an adjudication".
    """
    toks = [v for v in (verds or []) if v]
    if not toks:
        return "suspect"
    bases = {verdict_base(v) for v in toks}
    if bases & FATAL_VERDICTS:
        return "void"
    if bases & SUSPECT_VERDICTS:
        return "suspect"
    if bases & UNEVALUATED_VERDICTS:
        return "suspect"
    if bases - {V_OK}:
        return "suspect"        # an unrecognized token is never a pass
    return "ok"


def apply_status(current_status: Optional[str], floor: str) -> str:
    """Contract section 5 precedence. A crash ALWAYS wins: an already-`crash` row keeps
    status=crash and records its verdict in `validity` instead (now level-tagged, so the
    row says which level wedged). Otherwise a fatal floor forces `void`, a suspect floor
    forces `suspect`, and an `ok` floor leaves the caller's status untouched.

    v1.3: the caller's status is CHECKED against the section 6 vocabulary first, so a retired
    word (`keep`) or a typo raises instead of being laundered into the journal by the `ok`-floor
    pass-through. The `notes` half of check_status is not applied here -- apply_status is handed
    a status, not a row -- so a hand-set `discard` is stamp-checked by its writer (the
    orchestrator adjudicating the row), not by the precedence rule.
    """
    cur = check_status((current_status or "").strip() or STATUS_MEASURED)
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

    # A10: ONE assessment path. This is what validity.sh -> bench.sh actually executes, so
    # it must be the same function the acceptance suite exercises -- and it must default to
    # discover=False, matching the contract's "the caller's run-level list is authoritative".
    a = assess_bundle(args.bundle, levels, cells if cells else None,
                      node_profile=(args.node_profile or None),
                      bytes_per_token_gb=args.model_gb,
                      discover=bool(args.discover))
    print(json.dumps({
        "validity": a.validity,
        "req_counts": a.req_counts,
        "status_floor": a.status_floor,
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


def _cmd_status(args) -> int:
    """Validate a status word, or scan a results.tsv for §6/§7 violations.

    `--status W [--notes N]`  one word (and optionally the row's notes): 0 admissible,
                              EXIT_USAGE the word or the missing stamp is refused.
    `--tsv PATH ...`          every row of each journal: 0 clean, EXIT_INVALID if any row
                              carries a retired word or an unstamped hand-set status. This is
                              how the §7 rule is enforced over the committed record -- the
                              acceptance suite is hermetic and never reads the live results tree.
    """
    if args.status is not None:
        try:
            check_status(args.status, args.notes)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return EXIT_USAGE
        return EXIT_OK

    bad = 0
    for path in args.tsv:
        p = Path(path)
        try:
            lines = p.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            print("unreadable: %s: %s" % (p, exc), file=sys.stderr)
            bad += 1
            continue
        if not lines:
            continue
        header = lines[0].split("\t")
        try:
            si, ni, ri = header.index("status"), header.index("notes"), header.index("run_id")
        except ValueError:
            print("no status/notes/run_id column: %s" % p, file=sys.stderr)
            bad += 1
            continue
        for line in lines[1:]:
            if not line.strip():
                continue
            f = line.split("\t")
            if len(f) <= max(si, ni, ri):
                continue
            try:
                check_status(f[si], f[ni])
            except ValueError as exc:
                bad += 1
                print("%s\t%s\t%s" % (p, f[ri], exc), file=sys.stderr)
    if bad:
        print("%d row(s) violate the section 6/7 status rules" % bad, file=sys.stderr)
        return EXIT_INVALID
    return EXIT_OK


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
# v1.3: a USAGE error gets its own rung. It is NOT part of the 3 > 4 > 1 > 0 result ladder, which
# ranks outcomes of work that ran: 1 means "pre-measurement failure" (the serve or the smoke), and
# reporting a rejected INVOCATION as 1 told the caller a serve had been attempted and failed.
# 2 means the call was refused before anything was served, benched or written.
EXIT_USAGE = 2

# Public aliases. The names on the right are canonical; these are the shorter spellings
# consumers reach for first.
COLUMNS = RESULTS_COLS
LEVELS = LEVEL_COLUMNS      # the five fixed concurrency levels
STATUSES = STATUS_VOCAB


def __getattr__(name: str):
    """`SAFETY` is resolved on ACCESS, not bound at import (A10).

    It used to be a plain `SAFETY = AHL_ROOFLINE_SAFETY` assignment, which froze the value
    at import time: the documented override paths (env `AHL_ROOFLINE_SAFETY=…`, or
    reassigning the module attribute) moved the constant the rules read and left the public
    alias reporting the old number. A reader checking `validity.SAFETY` was told the
    override had not taken effect when it had.
    """
    if name == "SAFETY":
        return _cfg("AHL_ROOFLINE_SAFETY", float)
    raise AttributeError("module %r has no attribute %r" % (__name__, name))


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
                  bytes_per_token_gb=None, discover: bool = False) -> BundleAssessment:
    """Assess one run's bundle end to end (contract §3/§4/§5). THE entry point: the CLI
    (`validity.py check`, which validity.sh and therefore bench.sh run) calls this same
    function, so the tested path is the executed path (A10).

    `levels` is the list of levels that were RUN — authoritative over whatever files happen
    to be in the directory, so a stale level_c8.json from a previous shape is ignored and a
    level whose json vanished is still judged (`no_data`).

    `discover=False` (the default, and what a live bench must use): score exactly the
    caller's run levels. `discover=True` additionally scores any `level_c<N>.json` found on
    disk — for the audit/migration path, which reconstructs a run-level list it does not
    own. A10: these two used to give OPPOSITE verdicts on the same evidence, with the
    comment here asserting the inverse of what the code did.

    `node_profile` may be a path or an already-loaded mapping; without a readable
    `gpu.mem_bw_gbs` the roofline check is skipped, never guessed.
    """
    scanned = scan_bundle(bundle_dir, levels, tps, discover=discover)
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
    c.add_argument("--discover", action="store_true",
                   help="ALSO score level_c<N>.json files the caller did not list "
                        "(audit/migration only — a live bench must never pass this)")
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

    st = sub.add_parser("status", help="validate a §6 status word, or scan a results.tsv")
    st.add_argument("--status", default=None, help="the status word to validate")
    st.add_argument("--notes", default=None,
                    help="the row's notes, so a hand-set `discard` is checked for its "
                         "`adjudicated@YYYYMMDD who: reason` stamp (§7)")
    st.add_argument("--tsv", nargs="*", default=[], help="results.tsv files to scan instead")
    st.set_defaults(func=_cmd_status)

    sp = sub.add_parser("split", help="split a verdict token into base + level")
    sp.add_argument("token")
    sp.set_defaults(func=_cmd_split)

    av = sub.add_parser("addverdict", help="add verdict token(s) to a validity string")
    av.add_argument("validity")
    av.add_argument("tokens", nargs="+")
    av.set_defaults(func=lambda a: (print(add_verdict(a.validity, *a.tokens)), 0)[1])

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
