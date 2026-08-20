"""A throwaway repo in which the REAL enforcement scripts can be EXECUTED.

Why this exists
---------------
`tests/test_wiring.py` used to assert the §5 enforcement wiring with substring greps, and every
one of them was satisfiable by a comment. `assertRegex(src, r"knobs")` passes on the word `knobs`
in a docstring; `_needs("scripts/promote.sh", "void", "suspect")` passes on a line reading
`# void and suspect are not handled yet`; and NOTHING asserted that `bench.sh` passed
`--node-profile`, which is why the whole §4 roofline check was dead code on the primary bencher
while the suite reported 121/121 green (contract v1.2 A6/A8).

So the wiring tests execute the real script instead. `bench.sh` needs docker, a live vLLM
endpoint, `guidellm` and the GPU — none of which a test may touch (contract §8) — so this module
builds a directory that looks enough like the repo, copies the real scripts into it, and puts
LOGGING STUBS on `PATH` for everything the script shells out to:

    uv       -> answers `guidellm --version`, and writes a scripted level_c<N>.json for
                `guidellm benchmark run` instead of sending a request anywhere
    docker   -> logs and fails (the stall-watchdog is its only caller and never gets that far)
    adapter  -> info / health / peakmem / down, all canned

The assertions then read what a real run leaves behind: the emitted `results.tsv` row, the
process exit code, and the stub call log. That is the difference between "the string `4` appears
somewhere in bench.sh" and "bench.sh exits 4".

Same pattern, and the same motivating scar, as `scripts/citability_selftest.sh`.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

from . import api

NODE_FP = "gb10-test"
MODEL = "Org/Model"

# A scripted sweep: {level: {"ok":…, "incomplete":…, "errored":…, "tps":…, "out_tokens":…}}.
# A level mapped to None makes the stub exit non-zero WITHOUT writing its json — bench.sh's
# hang/crash path.
HEALTHY = {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "incomplete": 4, "tps": 200.0}}


def _write(path: Path, text: str, *, executable: bool = False) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


class ScratchRepo:
    """A minimal repo tree holding the real scripts and stubbed children."""

    def __init__(self, root, *, levels=None, mem_bw=273.0):
        self.root = Path(root)
        self.levels = dict(HEALTHY if levels is None else levels)
        self.log = self.root / "stub.log"
        self.out_dir = self.root / "results" / NODE_FP / "Org" / "Model"
        self.tsv = self.out_dir / "results.tsv"
        self.runbook = self.root / "runbooks" / "Org" / "Model" / "candidate_tuned.sh"
        self._build(mem_bw)

    # ── construction ──────────────────────────────────────────────────────────────────────
    def _build(self, mem_bw):
        r = self.root
        (r / "scripts" / "lib").mkdir(parents=True, exist_ok=True)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        (r / "backends" / "vllm").mkdir(parents=True, exist_ok=True)
        (r / "bin").mkdir(parents=True, exist_ok=True)

        for rel in ("scripts/bench.sh", "scripts/lib/validity.py", "scripts/lib/validity.sh",
                    "scripts/lib/__init__.py", "scripts/citability.py", "scripts/aggregate.py"):
            src = api.REPO_ROOT / rel
            if src.exists():
                shutil.copy2(src, r / rel)

        gpu = {"name": "GB10"}
        if mem_bw is not None:
            gpu["mem_bw_gbs"] = mem_bw
        _write(r / "results" / NODE_FP / "node_profile.json", json.dumps({"gpu": gpu}))
        _write(r / ".env", "# empty; bench.sh sources it\n")
        _write(self.runbook,
               "#!/usr/bin/env bash\n# image v0.25.0\nMODEL=Org/Model\nSERVED_NAME=m\n")

        _write(r / "backends" / "vllm" / "adapter.sh",
               "#!/usr/bin/env bash\n"
               f'echo "adapter $*" >> "{self.log}"\n'
               "case \"${1:-}\" in\n"
               "  info)    echo 'vllm@0.25.0(img:sha256:deadbeef)' ;;\n"
               "  health)  exit 0 ;;\n"
               "  peakmem) echo 'na' ;;\n"
               "  *)       exit 0 ;;\n"
               "esac\n", executable=True)

        _write(r / "scripts" / "metrics_sampler.sh",
               "#!/usr/bin/env bash\n"
               f'echo "metrics_sampler $*" >> "{self.log}"\n'
               '[ "${1:-}" = "--summary" ] && echo "thermal=na"\n'
               "exit 0\n", executable=True)

        _write(r / "bin" / "guidellm_stub.py", _GUIDELLM_STUB)
        _write(r / "bin" / "uv", _UV_STUB.format(py=sys.executable, root=r, log=self.log),
               executable=True)
        _write(r / "bin" / "docker",
               "#!/usr/bin/env bash\n"
               f'echo "docker $*" >> "{self.log}"\n'
               "exit 1\n", executable=True)

        # A python that answers `header` but fails `check`: a `uv` hiccup at verdict time, which
        # is the exact shape of the A6 fail-open defect ("STATUS_FLOOR=ok and exit 0").
        _write(r / "bin" / "flaky_python",
               "#!/usr/bin/env bash\n"
               'for a in "$@"; do\n'
               '  if [ "$a" = "check" ]; then\n'
               '    echo "simulated validity-library failure" >&2\n'
               "    exit 1\n"
               "  fi\n"
               "done\n"
               f'exec "{sys.executable}" "$@"\n', executable=True)

        # A python that logs its argv before running: this is how a test sees WHAT bench.sh
        # asked the validity library (contract A6 — "the harness must supply the roofline
        # input"; §4 was dead code on the vLLM path because `--node-profile` was never passed).
        _write(r / "bin" / "logging_python",
               "#!/usr/bin/env bash\n"
               f'echo "validity.py $*" >> "{self.log}"\n'
               f'exec "{sys.executable}" "$@"\n', executable=True)

        self.log.write_text("")
        self.levels_file = r / "levels.json"
        self._dump_levels()

    # The schema override used by the single-source-of-truth tests. Appending to the library
    # module works whatever the constants are literally spelled as, and every consumer that
    # genuinely reads them from the library sees the change (contract §1).
    SCHEMA_PATCH = '''

# ── appended by tests/ahl_test/scratch.py: rename the last column ────────────────────────────
_cols = list(globals().get("RESULTS_COLS") or globals()["COLUMNS"])
_cols = _cols[:-1] + ["data_SENTINEL"]
for _n in ("RESULTS_COLS", "COLUMNS"):
    if _n in globals():
        globals()[_n] = _cols
for _n in ("RESULTS_HEADER", "HEADER"):
    if _n in globals():
        globals()[_n] = "\\t".join(_cols)
'''

    def patch_library_schema(self):
        """Rename the last results.tsv column INSIDE this scratch repo's copy of validity.py.

        Contract §1: 'the header string previously existed in four hard-coded copies — all four
        now consume it from the library.' The only way to prove consumption rather than
        coincidence is to move the library and check that the consumer moved with it.
        """
        lib = self.root / "scripts" / "lib" / "validity.py"
        src = lib.read_text()
        # Before the `if __name__ == "__main__"` guard: appending after it would run the CLI
        # first and the override would never be seen by `validity.py header`.
        marker = 'if __name__ == "__main__":'
        idx = src.rfind(marker)
        lib.write_text(src + self.SCHEMA_PATCH if idx < 0
                       else src[:idx] + self.SCHEMA_PATCH + "\n\n" + src[idx:])
        return lib

    def _dump_levels(self):
        self.levels_file.write_text(json.dumps({str(k): v for k, v in self.levels.items()}))

    def set_levels(self, levels: dict):
        self.levels = dict(levels)
        self._dump_levels()

    # ── running ───────────────────────────────────────────────────────────────────────────
    def env(self, **extra) -> dict:
        e = dict(os.environ)
        e["PATH"] = f"{self.root / 'bin'}:{e.get('PATH', '')}"
        e["AHL_PYTHON"] = sys.executable          # keep validity.sh off `uv` and the network
        e["AHL_STUB_LEVELS"] = str(self.levels_file)
        e["LEVELS_SET"] = ",".join(str(k) for k in sorted(self.levels))
        e["MAX_SECONDS"] = "1"
        e["STALL_SECS"] = "3600"                  # the watchdog must never wake during a test
        e["LEVEL_TIMEOUT"] = "60"
        e.pop("STATUS", None)
        e.pop("NOTES", None)
        e.update({k: str(v) for k, v in extra.items()})
        return e

    def bench(self, *shapes, timeout: int = 180, **env) -> subprocess.CompletedProcess:
        """Execute the REAL scripts/bench.sh."""
        return self._run(
            ["bash", str(self.root / "scripts" / "bench.sh"), str(self.runbook),
             *(shapes or ("chat",))],
            env=self.env(**env), timeout=timeout)

    def _run(self, argv, *, env, timeout) -> subprocess.CompletedProcess:
        """Run a child with its output going to FILES, not pipes.

        Deliberate: bench.sh backgrounds a stall-watchdog whose own `sleep` child survives the
        `kill`, and an orphaned `sleep` holding the write end of a pipe makes `capture_output`
        block for the full sleep interval AFTER bench.sh has already exited. Redirecting to
        files means the test waits for the script, not for its stragglers.
        """
        self._seq = getattr(self, "_seq", 0) + 1
        o = self.root / f"out.{self._seq}"
        e = self.root / f"err.{self._seq}"
        with o.open("w") as fo, e.open("w") as fe:
            proc = subprocess.run(argv, cwd=str(self.root), stdout=fo, stderr=fe,
                                  timeout=timeout, env=env)
        return subprocess.CompletedProcess(argv, proc.returncode,
                                           o.read_text(), e.read_text())

    def aggregate(self, *args, timeout: int = 60) -> subprocess.CompletedProcess:
        """Execute the REAL scripts/aggregate.py against this tree."""
        e = self.env()
        e["AHL_RESULTS"] = str(self.root / "results")
        return self._run([sys.executable, str(self.root / "scripts" / "aggregate.py"),
                          *[str(a) for a in args]], env=e, timeout=timeout)

    # ── artefacts ─────────────────────────────────────────────────────────────────────────
    def rows(self) -> list:
        return api.read_tsv(self.tsv) if self.tsv.exists() else []

    def calls(self) -> str:
        return self.log.read_text() if self.log.exists() else ""

    def add_row(self, **cells) -> dict:
        """Append a hand-built results.tsv row (for consumers that only read the journal)."""
        cols = api.CONTRACT_COLUMNS
        base = {c: "na" for c in cols}
        base.update({"run_id": "20260819-000000-chat", "commit": "abc1234", "node_fp": NODE_FP,
                     "model": MODEL, "shape": "chat(512/256)", "backend": "vllm@0.25.0",
                     "config_hash": "cfg00000", "script": "runbooks/Org/Model/candidate_tuned.sh",
                     "load_s": "12.0", "max_s": "180", "seed": "42",
                     "req_counts": "c1:41/0/0;c16:118/4/0", "validity": "ok",
                     "knobs": "levels=1|16", "status": "measured", "notes": "na",
                     "data": "results/x/data/20260819-000000-chat"})
        base.update({k: str(v) for k, v in cells.items()})
        if not self.tsv.exists():
            self.tsv.write_text("\t".join(cols) + "\n")
        with self.tsv.open("a") as fh:
            fh.write("\t".join(base[c] for c in cols) + "\n")
        return base


_UV_STUB = """#!/usr/bin/env bash
# `uv` stand-in. Logs every call, answers guidellm itself, and runs `uv run ... python ...`
# on the real interpreter. It NEVER reaches the network or a container.
echo "uv $*" >> "{log}"
for a in "$@"; do
  if [ "$a" = "guidellm" ]; then
    exec "{py}" "{root}/bin/guidellm_stub.py" "$@"
  fi
done
args=(); seen_python=0; skip_next=0
for a in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$a" in
    --project) skip_next=1; continue ;;
    run|--quiet|--offline|--no-project) continue ;;
    python|python3) seen_python=1; continue ;;
  esac
  [ "$seen_python" = 1 ] && args+=("$a")
done
[ "$seen_python" = 1 ] || {{ echo "uv stub: unhandled invocation: $*" >&2; exit 127; }}
exec "{py}" "${{args[@]}}"
"""

_GUIDELLM_STUB = '''#!/usr/bin/env python3
"""Stands in for `guidellm` inside a ScratchRepo. Never opens a socket.

`--version` prints the pinned 0.6.0. `benchmark run --rate N --output-path P` writes the level
JSON the test scripted for level N, or exits 3 WITHOUT writing it (bench.sh's hang path) when
that level was scripted as null.
"""
import json
import os
import sys


def level_json(successful, errored, incomplete, tps, rate, out_tokens):
    total = successful + errored + incomplete

    def stat(mean, count):
        return {"mean": mean, "median": mean, "mode": mean, "variance": 0.0, "std_dev": 0.0,
                "min": mean, "max": mean, "count": count, "total_sum": mean * count,
                "percentiles": {}, "pdf": None}

    def metric(mean_ok):
        return {"successful": stat(mean_ok, successful), "errored": stat(0.0, errored),
                "incomplete": stat(0.0, incomplete), "total": stat(mean_ok, total)}

    return {
        "metadata": {"version": 1, "guidellm_version": "0.6.0"},
        "args": {"rate": [float(rate)], "max_seconds": 180.0, "profile": "concurrent",
                 "random_seed": 42, "processor": "Org/Model",
                 "data": ["prompt_tokens=512,output_tokens=256"]},
        "benchmarks": [{
            "type_": "generative_benchmark", "start_time": 0.0, "end_time": 1.0,
            "duration": 1.0,
            "metrics": {
                "request_totals": {"successful": successful, "errored": errored,
                                   "incomplete": incomplete, "total": total},
                "output_tokens_per_second": metric(tps),
                "request_concurrency": metric(float(rate)),
                "output_token_count": metric(out_tokens),
                "prompt_token_count": metric(512.0),
                "requests_per_second": metric(0.5),
                "request_latency": metric(1.0),
            },
            "scheduler_state": {"created_requests": total, "processed_requests": total,
                                "successful_requests": successful, "errored_requests": errored,
                                "cancelled_requests": incomplete},
        }],
    }


def main(argv):
    if "--version" in argv:
        print("guidellm, version 0.6.0")
        return 0
    rate = out = None
    for i, a in enumerate(argv):
        if a == "--rate":
            rate = argv[i + 1]
        elif a == "--output-path":
            out = argv[i + 1]
    spec = json.load(open(os.environ["AHL_STUB_LEVELS"]))
    level = spec.get(str(int(float(rate))))
    if level is None:
        sys.stderr.write("scripted hang at c%s\\n" % rate)
        return 3
    doc = level_json(int(level.get("ok", 41)), int(level.get("errored", 0)),
                     int(level.get("incomplete", 0)), float(level.get("tps", 100.0)),
                     float(rate), float(level.get("out_tokens", 251.75)))
    with open(out, "w") as fh:
        json.dump(doc, fh)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'''
