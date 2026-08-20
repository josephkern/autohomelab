#!/usr/bin/env python3
"""Gate-2 ACCEPTANCE PREDICATE — "is this lm-eval score a measurement at all?"

    uv run scripts/eval_validity.py assess --bundle DIR --tasks gsm8k,mmlu [--limit 100]
                                           [--conc 16] [--format tsv|json]

Why this file exists (docs/validity-contract.md A9)
---------------------------------------------------
`scripts/lib/validity.py` is the acceptance predicate for Gate 3 (throughput): it reads GuideLLM
level JSON and decides whether a tok/s number may be quoted. Gate 2 (quality) had **no acceptance
predicate at all**. `suite.sh` computed Gate 2 from `eval.sh`'s exit code only, and `eval.sh`
exited 0 whatever came back, so all three of these reported **PASS**:

    lm-eval printed `mmlu: acc = NaN`            -> accuracy.tsv `mmlu=nan`    -> Gate 2 PASS
    lm-eval scored 37 of 14,042 requested docs   -> accuracy.tsv `mmlu=41.23`  -> Gate 2 PASS
    lm-eval produced no results json at all      -> accuracy.tsv `na`          -> Gate 2 PASS

The first two are the §0 defect (c) that motivated the whole validity contract: a spec-decode
config scored by a loglikelihood task that returned NaN for 56,168 requests while the progress bar
advanced normally for 75 minutes. lm-eval **retries and keeps going**, so it neither aborts nor
exits non-zero; it reports a score over whatever subset happened to survive. An exit code cannot
see that. The evidence can: every lm-eval bundle carries `n-samples` with `effective` and
`original` per task.

What this is NOT
----------------
A validity check, never a tolerance test. It answers "is this a number?", not "is this number
good?". In particular it deliberately does NOT check a score against a reference or demand a
sample size: at the in-loop `LIMIT=100` the binomial standard error is ~4.3 points at p~0.9
(AGENTS.md), far wider than the ~1% KEEP tolerance, so any threshold on the *value* would imply a
precision the sample size cannot deliver. Every rule below is structural.

Vocabulary (mirrors the throughput layer — one concept, not two)
----------------------------------------------------------------
Verdict tokens are TASK-tagged the way Gate-3 tokens are level-tagged (contract §3 v1.1):
`nonfinite@mmlu`, `short_sample@gsm8k`. `+`-joined, `ok` when clean, `na` when the rules could not
be evaluated. `status_floor`/`apply_status` mirror §5: a fatal token forces `void`, a suspect token
forces `suspect`, and the caller exits 4 ("the row is written but not citable").

| token          | rule                                                        | severity |
|----------------|-------------------------------------------------------------|----------|
| `no_score`     | no results json, unparseable, or the task has no metric      | fatal    |
| `nonfinite`    | the headline metric is NaN or +/-Inf                         | fatal    |
| `short_sample` | `effective < FRAC * requested` (FRAC = 0.99)                 | fatal    |
| `zero_score`   | the headline metric is exactly 0.0                           | suspect  |
| `no_samples`   | the bundle carries no `n-samples`, so the count check could  | suspect  |
|                | not run — fail CLOSED (contract A6)                          |          |

`FRAC = 0.99` (`AHL_EVAL_MIN_SAMPLE_FRAC`). A healthy lm-eval run has `effective == requested`
exactly — `requested` is `min(limit, original)` summed over the task's leaf subtasks, which is how
`mmlu --limit 100` legitimately requests 5,700 docs from a 14,042-doc corpus and not 100. The 1%
slack exists only so a single dropped doc in a 12,000-doc `FULL` run is reported rather than
fatal; it still fails the motivating case (37/14,042 = 0.26%) by two orders of magnitude.

`zero_score` is suspect rather than fatal because a genuine 0.0 is possible on a hard task, but it
is far more often a broken path than a measurement — AGENTS.md records **NemotronH generating zero
tokens** under `enable_thinking=false` (gsm8k think-off 0.0, fixed by `AHL_THINK_OFF_KWARGS`), and
the `minerva_math500` `\\boxed` extraction mismatch scoring ~0 "for a format mismatch, NOT a real
failure". Neither is citable as a quality result. Three rows in the committed corpus are 0.0.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path

NA = "na"

# ── verdict vocabulary (mirrors lib/validity.py's §3 shape) ───────────────────
V_OK = "ok"
V_NO_SCORE = "no_score"
V_NONFINITE = "nonfinite"
V_SHORT_SAMPLE = "short_sample"
V_ZERO_SCORE = "zero_score"
V_NO_SAMPLES = "no_samples"

VERDICT_ORDER = (V_NO_SCORE, V_NONFINITE, V_SHORT_SAMPLE, V_ZERO_SCORE, V_NO_SAMPLES)
FATAL_VERDICTS = frozenset({V_NO_SCORE, V_NONFINITE, V_SHORT_SAMPLE})
SUSPECT_VERDICTS = frozenset({V_ZERO_SCORE, V_NO_SAMPLES})
ROW_WIDE_VERDICTS = frozenset({V_OK})

# ── status vocabulary (contract §6; the subset Gate 2 can produce) ────────────
STATUS_MEASURED = "measured"
STATUS_SUSPECT = "suspect"
STATUS_VOID = "void"
STATUS_CRASH = "crash"


# ── accuracy.tsv schema — the ONE definition ──────────────────────────────────
# results.tsv's header lives once, in lib/validity.py, because four hard-coded copies
# disagreeing with the reference is the defect issue #1 opened on. The accuracy journal
# had grown five copies of its own header across the eval scripts; they are consumed from
# here instead. `accuracy.sh-header` prints it for the bash callers.
ACCURACY_LEGACY_COLS = ["run_id", "commit", "node_fp", "model", "config_hash", "script",
                        "suite", "tasks", "limit", "scores", "data", "think"]
ACCURACY_NEW_COLS = ["conc", "samples", "validity", "status"]
ACCURACY_COLS = ACCURACY_LEGACY_COLS + ACCURACY_NEW_COLS
ACCURACY_HEADER = "\t".join(ACCURACY_COLS)


def _cfg_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


#: `effective / requested` must reach this or the score is not over the population claimed.
MIN_SAMPLE_FRAC = _cfg_float("AHL_EVAL_MIN_SAMPLE_FRAC", 0.99)

# The metric a task's headline score comes from, in preference order. This list is lifted
# verbatim from the extractor that used to live in eval.sh's heredoc so historical rows stay
# comparable (verified: it reproduces all 76 committed `scores` cells exactly).
METRIC_KEYS = (
    "exact_match,strict-match",
    "exact_match,flexible-extract",
    "exact_match,custom-extract",
    "acc,none",
    "acc_norm,none",
    "pass@1,none",
    "acc",
    "pass@1",
)
# Bookkeeping fields that are numeric but are not scores.
_SKIP_KEYS = {"sample_len", "samples", "sample_count", "alias", "name"}

_TAGGED = re.compile(r"^([a-z_]+)@([A-Za-z0-9_.\-]+)$")


def tag_verdict(base: str, task=None) -> str:
    if task is None or base in ROW_WIDE_VERDICTS:
        return base
    return "%s@%s" % (base, task)


def split_verdict(token: str):
    """`nonfinite@mmlu` -> ("nonfinite", "mmlu"); `ok` -> ("ok", None)."""
    tok = (token or "").strip()
    m = _TAGGED.match(tok)
    if m:
        return m.group(1), m.group(2)
    return tok, None


def verdict_base(token: str) -> str:
    return split_verdict(token)[0]


def _sort_key(token: str):
    base, task = split_verdict(token)
    try:
        rank = VERDICT_ORDER.index(base)
    except ValueError:
        rank = len(VERDICT_ORDER)
    return (rank, task or "", base)


def format_validity(verds) -> str:
    seen = {v for v in (verds or []) if v and v != V_OK}
    return "+".join(sorted(seen, key=_sort_key)) if seen else V_OK


def parse_validity(s):
    if not s:
        return [V_OK]
    s = s.strip()
    if s in ("", NA, V_OK):
        return [V_OK]
    return [t for t in (p.strip() for p in s.split("+")) if t]


def status_floor(verds) -> str:
    bases = {verdict_base(v) for v in (verds or []) if v}
    if bases & FATAL_VERDICTS:
        return STATUS_VOID
    if bases & SUSPECT_VERDICTS:
        return STATUS_SUSPECT
    return "ok"


def apply_status(current, floor) -> str:
    """Contract §5 precedence. A crash always wins; otherwise the floor forces the status."""
    cur = (current or "").strip() or STATUS_MEASURED
    if cur == STATUS_CRASH:
        return STATUS_CRASH
    if floor == STATUS_VOID:
        return STATUS_VOID
    if floor == STATUS_SUSPECT:
        return STATUS_SUSPECT
    return cur


def citable(validity: str, status: str = "") -> bool:
    """The one question every consumer asks. `na` is NEVER citable (contract A5): "rules could
    not be evaluated" is not a pass, and neither is any non-`ok` verdict (contract §5: bench.sh
    exits 4 on a suspect verdict alone)."""
    raw = (validity or "").strip().lower()
    if raw in ("", NA):
        return False
    if (status or "").strip().lower() in (STATUS_VOID, STATUS_SUSPECT, STATUS_CRASH):
        return False
    return status_floor(parse_validity(raw)) == "ok"


# ── bundle reading ────────────────────────────────────────────────────────────
def find_results_json(bundle):
    """lm-eval writes `<bundle>/<model_sanitized>/results_<ts>.json`. Older/other layouts put it
    directly under the bundle. Newest wins if a bundle was written more than once."""
    p = Path(bundle)
    if p.is_file():
        return p
    if not p.is_dir():
        return None
    hits = sorted(p.glob("**/results_*.json"))
    return hits[-1] if hits else None


def _leaf_tasks(task, group_subtasks, seen=None):
    """Expand a group task to the leaves that own the samples: `mmlu` -> 57 `mmlu_*`."""
    seen = seen or set()
    if task in seen:
        return []
    seen.add(task)
    kids = (group_subtasks or {}).get(task)
    if not kids:
        return [task]
    out = []
    for k in kids:
        out.extend(_leaf_tasks(k, group_subtasks, seen))
    return out


def _requested(original, limit):
    """lm-eval's own rule: a limit >= 1 is a document count, a limit in (0,1) is a fraction."""
    if limit is None:
        return int(original)
    try:
        lim = float(limit)
    except (TypeError, ValueError):
        return int(original)
    if lim <= 0:
        return int(original)
    if lim < 1.0:
        return int(int(original) * lim)
    return min(int(original), int(lim))


def _headline(metrics):
    """(key, value) for the task's headline metric, or (None, None)."""
    for k in METRIC_KEYS:
        if k in metrics:
            return k, metrics[k]
    nums = {k: v for k, v in metrics.items()
            if isinstance(v, (int, float)) and not isinstance(v, bool)
            and "stderr" not in k and k not in _SKIP_KEYS}
    if nums:
        k = next(iter(nums))
        return k, nums[k]
    return None, None


def _fmt_score(value):
    if value is None:
        return NA
    if isinstance(value, float) and math.isnan(value):
        return "nan"
    if isinstance(value, float) and math.isinf(value):
        return "inf" if value > 0 else "-inf"
    # `str(round(x*100, 2))` reproduces the exact text eval.sh has always written ("42.0",
    # "78.19"), so a migrated row and a new row are byte-comparable.
    return str(round(float(value) * 100, 2))


def assess(bundle, tasks, limit=None, conc=None, status=None):
    """The predicate. Returns a dict with `scores`, `samples`, `validity`, `status`, `conc`,
    `citable` and a human `reasons` list. Never raises on a malformed bundle: an unreadable
    bundle is a verdict, not a crash."""
    want = [t.strip() for t in (tasks or "").split(",") if t.strip()] if isinstance(tasks, str) \
        else [str(t).strip() for t in (tasks or []) if str(t).strip()]
    res = {
        "scores": NA, "samples": NA, "validity": NA, "status": NA,
        "conc": str(conc) if conc not in (None, "") else NA,
        "citable": False, "reasons": [], "results_json": NA,
    }

    path = find_results_json(bundle) if bundle else None
    if path is None:
        # No results json AT ALL. Today this writes `scores=na` and passes; contract A9 item 3
        # makes it a failure. Task-tagging is impossible here, so the token is row-wide.
        res["validity"] = format_validity([V_NO_SCORE])
        res["status"] = apply_status(status, status_floor([V_NO_SCORE]))
        res["reasons"].append("no results_*.json under %s — lm-eval produced no score" % bundle)
        return res
    res["results_json"] = str(path)
    try:
        with open(path) as f:
            doc = json.load(f)          # json.load parses a bare NaN/Infinity literal to a float
    except Exception as exc:            # noqa: BLE001 — any read/parse failure is one verdict
        res["validity"] = format_validity([V_NO_SCORE])
        res["status"] = apply_status(status, status_floor([V_NO_SCORE]))
        res["reasons"].append("results json unreadable (%s): %s" % (path, exc))
        return res

    results = doc.get("results") or {}
    group_subtasks = doc.get("group_subtasks") or {}
    nsamples = doc.get("n-samples") or {}
    cfg = doc.get("config") or {}
    if limit is None:
        limit = cfg.get("limit")
    margs = cfg.get("model_args") or {}
    if isinstance(margs, str):
        margs = dict(p.split("=", 1) for p in margs.split(",") if "=" in p)
    if margs.get("num_concurrent") not in (None, ""):
        res["conc"] = str(margs["num_concurrent"])

    if not want:
        want = [t for t in results if t in nsamples or t in group_subtasks]

    verds, scores, samples = [], [], []
    for task in want:
        metrics = results.get(task)
        if not isinstance(metrics, dict):
            verds.append(tag_verdict(V_NO_SCORE, task))
            res["reasons"].append("%s: requested but absent from the results json" % task)
            samples.append("%s=%s" % (task, NA))
            continue
        key, value = _headline(metrics)
        scores.append("%s=%s" % (task, _fmt_score(value)))
        if key is None or value is None:
            verds.append(tag_verdict(V_NO_SCORE, task))
            res["reasons"].append("%s: no recognizable accuracy metric in %s"
                                  % (task, sorted(metrics)))
        elif not math.isfinite(float(value)):
            verds.append(tag_verdict(V_NONFINITE, task))
            res["reasons"].append("%s: %s is %s — not a number" % (task, key, value))
        elif float(value) == 0.0:
            verds.append(tag_verdict(V_ZERO_SCORE, task))
            res["reasons"].append("%s: %s is exactly 0.0 — check the serve produced tokens at "
                                  "all (AGENTS.md: NemotronH think-off generates zero tokens) "
                                  "and that the answer extractor matches the output format"
                                  % (task, key))

        # Sample-count check: effective vs requested, summed over the leaves that own the docs.
        leaves = [t for t in _leaf_tasks(task, group_subtasks) if t in nsamples]
        if not leaves and task in nsamples:
            leaves = [task]
        if not leaves:
            verds.append(tag_verdict(V_NO_SAMPLES, task))
            res["reasons"].append("%s: no `n-samples` entry — the completeness check could not "
                                  "run, so the score is not citable (fail closed)" % task)
            samples.append("%s=%s" % (task, NA))
            continue
        eff = req = 0
        for leaf in leaves:
            ent = nsamples.get(leaf) or {}
            eff += int(ent.get("effective") or 0)
            req += _requested(int(ent.get("original") or 0), limit)
        samples.append("%s=%d/%d" % (task, eff, req))
        if req > 0 and eff < MIN_SAMPLE_FRAC * req:
            verds.append(tag_verdict(V_SHORT_SAMPLE, task))
            res["reasons"].append(
                "%s: scored %d of %d requested samples (%.2f%%, floor %.0f%%) — the score is "
                "over a different population than the one asked for"
                % (task, eff, req, 100.0 * eff / req, 100.0 * MIN_SAMPLE_FRAC))

    res["scores"] = ";".join(sorted(scores)) or NA
    res["samples"] = ";".join(sorted(samples)) or NA
    res["validity"] = format_validity(verds)
    res["status"] = apply_status(status, status_floor(verds))
    res["citable"] = citable(res["validity"], res["status"])
    return res


# ── CLI ───────────────────────────────────────────────────────────────────────
def cmd_assess(args) -> int:
    out = assess(args.bundle, args.tasks, limit=args.limit, conc=args.conc, status=args.status)
    if args.format == "json":
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        # One tab-separated line the shell reads with `IFS=$'\t' read -r`.
        print("\t".join((out["scores"], out["samples"], out["validity"], out["status"],
                         out["conc"], "1" if out["citable"] else "0")))
    for r in out["reasons"]:
        print("  ! " + r, file=sys.stderr)
    return 0 if out["citable"] else 4


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("assess", help="score + verdict for one lm-eval bundle")
    a.add_argument("--bundle", required=True, help="the run's bundle dir (or the results json)")
    a.add_argument("--tasks", default="", help="comma-separated top-level tasks that were asked for")
    a.add_argument("--limit", default=None, help="per-task cap that was requested (default: read "
                                                 "the bundle's own config.limit)")
    a.add_argument("--conc", default=None, help="fallback concurrency if the bundle lacks it")
    a.add_argument("--status", default="", help="caller's status, floored per contract §5")
    a.add_argument("--format", default="tsv", choices=("tsv", "json"))
    a.set_defaults(fn=cmd_assess)

    h = sub.add_parser("accuracy-header",
                       help="print the accuracy.tsv header (the one definition)")
    h.set_defaults(fn=lambda _a: _print_accuracy_header())

    args = ap.parse_args(argv)
    return args.fn(args)


def _print_accuracy_header() -> int:
    print(ACCURACY_HEADER)
    return 0


if __name__ == "__main__":
    sys.exit(main())
