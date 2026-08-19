"""Locate + normalize the implementation under test (`scripts/lib/validity.py`).

Design note — why this file exists at all
-----------------------------------------
`docs/validity-contract.md` fixes the *rules* and the *file path* but not the Python signatures.
This suite was written before `scripts/lib/validity.py` existed, so it resolves the callables by
a small alias table and maps its canonical keyword arguments onto whatever parameter names the
implementation actually chose (via `inspect.signature`). Everything that has to be guessed is
guessed HERE, in one file — if the merged implementation names things differently, one edit to
the alias tables below re-points the whole suite.

The surface the suite prefers (and that `tests/README.md` documents as the requirement):

    COLUMNS: list[str]            # the 23 results.tsv column names, in contract order
    HEADER:  str                  # "\\t".join(COLUMNS)

    assess_bundle(bundle_dir, levels, node_profile=None, status="measured",
                  bytes_per_token_gb=None) -> Verdict
        bundle_dir : directory holding level_c<N>.json files
        levels     : the concurrency levels that were RUN (e.g. [1, 16]); every other column
                     stays `na` and MUST NOT be scored (contract §3)
        Verdict    : object or dict exposing .validity (str), .status (str, post-downgrade),
                     .req_counts (str)

    format_req_counts(mapping) -> str        parse_req_counts(str) -> mapping
    format_knobs(mapping)      -> str        parse_knobs(str)      -> mapping
"""
from __future__ import annotations

import inspect
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = TESTS_DIR.parent
FIXTURES = TESTS_DIR / "fixtures"
LIB_DIR = REPO_ROOT / "scripts" / "lib"
VALIDITY_PY = LIB_DIR / "validity.py"
VALIDITY_SH = LIB_DIR / "validity.sh"
MIGRATE_PY = REPO_ROOT / "scripts" / "migrate_results_tsv.py"

# The 23 columns of contract §2, in order. This is the test's own copy on purpose: the whole
# point of the schema test is to compare the implementation against an independent transcript.
CONTRACT_COLUMNS = [
    "run_id", "commit", "node_fp", "model", "shape", "backend", "config_hash", "script",
    "load_s", "max_s", "seed",
    "tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32", "peak_gb",
    "req_counts", "validity", "knobs",
    "status", "notes", "data",
]
LEGACY_COLUMNS = [c for c in CONTRACT_COLUMNS if c not in ("req_counts", "validity", "knobs")]

ALL_LEVELS = (1, 4, 8, 16, 32)


# ── module loading ────────────────────────────────────────────────────────────────────────────
def load_validity(env: dict[str, str] | None = None):
    """Import scripts/lib/validity.py fresh (so AHL_* env overrides are re-read). None if absent."""
    if not VALIDITY_PY.exists():
        return None
    import importlib.util

    old = dict(os.environ)
    if env:
        os.environ.update(env)
    try:
        spec = importlib.util.spec_from_file_location("ahl_validity_under_test", VALIDITY_PY)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["ahl_validity_under_test"] = mod
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        return mod
    finally:
        os.environ.clear()
        os.environ.update(old)


def require_validity(test: unittest.TestCase, env: dict[str, str] | None = None):
    mod = load_validity(env)
    if env:
        # The library reads AHL_* at CALL time (so `AHL_MIN_SUCCESSFUL=40 scripts/bench.sh`
        # works), not at import time. Keep the override in place for the duration of the
        # test rather than only across the import.
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)

        def _restore():
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

        test.addCleanup(_restore)
    if mod is None:
        test.skipTest(
            f"not implemented yet: {VALIDITY_PY.relative_to(REPO_ROOT)} "
            "(A1 owns it; contract §1)"
        )
    return mod


def attr(test: unittest.TestCase, mod, *names, what: str = ""):
    """First present attribute among `names`, else skip naming all of them."""
    for n in names:
        if hasattr(mod, n):
            return getattr(mod, n)
    test.skipTest(
        f"scripts/lib/validity.py exposes none of {list(names)}"
        + (f" — needed for {what}" if what else "")
    )


# ── signature-tolerant invocation ─────────────────────────────────────────────────────────────
_PARAM_ALIASES = {
    "bundle_dir": ("bundle_dir", "bundle", "bundle_path", "data_dir", "datadir", "dirpath",
                   "path", "directory", "dir"),
    "levels": ("levels", "run_levels", "levels_run", "levels_set", "rates", "concurrencies",
               "concurrency_levels"),
    "node_profile": ("node_profile", "node", "profile", "node_profile_path", "profile_path"),
    "status": ("status", "base_status", "caller_status"),
    "bytes_per_token_gb": ("bytes_per_token_gb", "bytes_per_token", "model_gb",
                           "active_weight_gb", "weight_gb"),
}

_ASSESS_NAMES = ("assess_bundle", "assess", "evaluate_bundle", "validate_bundle",
                 "check_bundle", "verdict_for_bundle", "bundle_verdict")


class Verdict:
    """Normalized view of whatever assess_bundle returned."""

    def __init__(self, raw):
        self.raw = raw
        self.validity = _pick(raw, "validity", "verdict", "verdicts", "validity_str")
        self.status = _pick(raw, "status", "status_floor", "downgraded_status", "final_status")
        self.req_counts = _pick(raw, "req_counts", "request_counts", "req_counts_str", "counts")

    @property
    def tagged(self) -> set[str]:
        """Verdict tokens exactly as emitted, e.g. {"no_data@c32"} (contract v1.1 §3)."""
        v = self.validity
        if v is None:
            return set()
        if isinstance(v, (list, tuple, set)):
            raw = {str(t) for t in v}
        else:
            raw = {t for t in str(v).split("+") if t}
        return raw

    @property
    def tokens(self) -> set[str]:
        """Tagged tokens PLUS their bare base names.

        v1.1 tags a token with the level it refers to (`low_sample@c1`) so a thin c1
        sentinel cannot condemn a campaign's c16 objective. Tests that assert on the rule
        ("this is low_sample") stay valid; tests that assert on the level use `.tagged`.
        """
        out = set()
        for t in self.tagged:
            out.add(t)
            out.add(t.split("@", 1)[0])
        return out

    def __repr__(self):  # shows up in assertion failure messages
        return (f"Verdict(validity={self.validity!r}, status={self.status!r}, "
                f"req_counts={self.req_counts!r})")


def _pick(raw, *names):
    for n in names:
        if isinstance(raw, dict):
            if n in raw:
                return raw[n]
        elif hasattr(raw, n):
            return getattr(raw, n)
    return None


def assess(test: unittest.TestCase, mod, bundle_dir, levels, *,
           node_profile=None, status="measured", bytes_per_token_gb=None) -> Verdict:
    """Call the implementation's bundle assessor, mapping our kwargs onto its parameter names."""
    fn = attr(test, mod, *_ASSESS_NAMES, what="the per-row verdict (contract §3/§5)")
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        sig = None

    canonical = {
        "bundle_dir": Path(bundle_dir),
        "levels": list(levels),
        "node_profile": node_profile,
        "status": status,
        "bytes_per_token_gb": bytes_per_token_gb,
    }

    if sig is None:
        return Verdict(fn(Path(bundle_dir), list(levels)))

    params = sig.parameters
    accepts_kwargs = any(p.kind is inspect.Parameter.VAR_KEYWORD for p in params.values())
    kwargs: dict[str, object] = {}
    unmapped: list[str] = []
    for key, value in canonical.items():
        if value is None and key in ("node_profile", "bytes_per_token_gb"):
            continue
        name = next((a for a in _PARAM_ALIASES[key] if a in params), None)
        if name is None and accepts_kwargs:
            name = _PARAM_ALIASES[key][0]
        if name is None:
            unmapped.append(key)
            continue
        if key == "node_profile":
            value = _profile_arg(name, value, test)
        kwargs[name] = value

    if "bundle_dir" in unmapped or "levels" in unmapped:
        test.skipTest(
            f"{fn.__name__}{sig} does not accept a bundle directory and a run-level list; "
            f"tried aliases {_PARAM_ALIASES['bundle_dir']} / {_PARAM_ALIASES['levels']} "
            "(see tests/ahl_test/api.py)"
        )
    for key in unmapped:
        test.skipTest(f"{fn.__name__}{sig} has no parameter for {key!r} — cannot test it")

    return Verdict(fn(**kwargs))


def _profile_arg(param_name: str, profile, test):
    """Pass the node profile as a path or a dict, whichever the parameter name suggests."""
    if profile is None:
        return None
    wants_path = param_name.endswith("_path")
    if isinstance(profile, (str, Path)):
        if wants_path:
            return Path(profile)
        return json.loads(Path(profile).read_text())
    return profile  # already a dict; hand it over as-is


# ── fixture helpers ───────────────────────────────────────────────────────────────────────────
def level_json(successful: int, errored: int = 0, incomplete: int = 0, tps: float = 100.0,
               rate: int = 1, max_seconds: float = 180.0) -> dict:
    """A synthetic GuideLLM 0.6.0 level bundle carrying the fields the layer reads.

    Counts are written in BOTH places real bundles carry them — `metrics.request_totals` and
    `metrics.<m>.{successful,errored,incomplete}.count` — so the test does not depend on which
    one the implementation happens to read.
    """
    total = successful + errored + incomplete

    def stat(mean, count):
        return {"mean": mean, "median": mean, "mode": mean, "variance": 0.0, "std_dev": 0.0,
                "min": mean, "max": mean, "count": count, "total_sum": mean * count,
                "percentiles": {}, "pdf": None}

    def metric(mean_ok):
        return {"successful": stat(mean_ok, successful), "errored": stat(0.0, errored),
                "incomplete": stat(0.0, incomplete), "total": stat(mean_ok, total)}

    return {
        "metadata": {"version": 1, "guidellm_version": "0.6.0", "python_version": "3.12.3",
                     "platform": "Linux-6.17.0-1021-nvidia-aarch64-with-glibc2.39"},
        "args": {"rate": [float(rate)], "max_seconds": max_seconds, "profile": "concurrent",
                 "random_seed": 42, "processor": "org/model",
                 "data": ["prompt_tokens=512,output_tokens=256"]},
        "benchmarks": [{
            "type_": "generative_benchmark",
            "start_time": 0.0, "end_time": max_seconds, "duration": max_seconds,
            "metrics": {
                "request_totals": {"successful": successful, "errored": errored,
                                   "incomplete": incomplete, "total": total},
                "output_tokens_per_second": metric(tps),
                "request_concurrency": metric(float(rate)),
                "output_token_count": metric(256.0),
                "prompt_token_count": metric(512.0),
                "requests_per_second": metric(tps / 256.0 if tps else 0.0),
                "request_latency": metric(1.0),
            },
            "scheduler_state": {"created_requests": total, "processed_requests": total,
                                "successful_requests": successful, "errored_requests": errored,
                                "cancelled_requests": incomplete},
        }],
    }


def write_bundle(dirpath: Path, levels: dict[int, dict | str | None]) -> Path:
    """Materialize a bundle dir. Value None => the level_cN.json is deliberately ABSENT;
    a str value is written verbatim (for the unparseable case)."""
    dirpath.mkdir(parents=True, exist_ok=True)
    for level, payload in levels.items():
        target = dirpath / f"level_c{level}.json"
        if payload is None:
            if target.exists():
                target.unlink()
            continue
        if isinstance(payload, str):
            target.write_text(payload)
        else:
            target.write_text(json.dumps(payload))
    return dirpath


def copy_fixture_bundle(name: str, dest: Path) -> Path:
    """Copy tests/fixtures/<name>/ (a minimized real bundle) into a temp dir so a test may
    delete or corrupt a level without touching the committed fixture."""
    import shutil

    src = FIXTURES / name
    dest.mkdir(parents=True, exist_ok=True)
    for f in sorted(src.glob("level_c*.json")):
        shutil.copy2(f, dest / f.name)
    return dest


# ── other implementations under test ──────────────────────────────────────────────────────────
def require_file(test: unittest.TestCase, path: Path, owner: str):
    if not path.exists():
        test.skipTest(f"not implemented yet: {path.relative_to(REPO_ROOT)} ({owner})")
    return path


def run_python(script: Path, *args, cwd: Path | None = None):
    """Run a repo python script the charter-approved way (uv, offline, no project deps)."""
    uv = _uv()
    cmd = ([uv, "run", "--no-project", "--offline", "python"] if uv else [sys.executable]) + \
        [str(script), *[str(a) for a in args]]
    return subprocess.run(cmd, cwd=str(cwd or REPO_ROOT), capture_output=True,
                          text=True, timeout=60)


def _uv():
    from shutil import which
    return which("uv")
