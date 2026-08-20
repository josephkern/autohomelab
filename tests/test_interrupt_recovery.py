"""An INTERRUPTED bench must still leave a journal row — executed, not asserted about.

The hole this module pins down: `bench.sh` emits its `results.tsv` row once, after the level
loop. Kill the process mid-shape (operator Ctrl-C, session limit, `kill`, a reboot) and the
`data/<run_id>/` bundle survives on disk holding real `level_c*.json` evidence that **no row
references** — invisible to `aggregate.py`, to the audit, and to every gate. Two such orphans
exist in this node's tree today (a complete two-level sweep, and a c1-only partial).

Every test here runs the REAL `scripts/bench.sh` in a `ScratchRepo` and signals it *while it is
inside a level*, then reads what the run left behind: the row, its cells, the exit status. The
scar this repo keeps re-learning is a correct condition in an unreachable branch, and no
assertion about the trap's condition could catch that — only sending the signal can.

Determinism: the stock guidellm stub returns instantly, which leaves no window to signal. These
tests swap in a stub that, for levels listed in `AHL_STUB_BLOCK`, touches a marker file and then
sleeps. The harness waits for the marker (so the process is provably *inside* that level) and
only then signals. No timing guesses. The same trick is applied to `head`, `adapter peakmem`,
`metrics_sampler --summary` and `sleep`, which puts a deterministic signal point inside every
window this module cares about: mid-append, mid-crash-recording, mid-handler, and mid-watchdog.

What the first version of this module missed, and what each of the later classes exists for:

  * `TestTheWriteIsTheAtomicUnit` — "exactly once" also has to hold in the ZERO direction. The
    flag used to come down BEFORE the append, so a signal at any of the six command boundaries
    inside `emit_row` lost the row of a sweep that had FINISHED.
  * `TestNoProcessOutlivesTheRun` / `TestTheWatchdogTripsScoped` — the stall-watchdog was orphaned
    by the interrupt path and kept firing a box-wide `pkill`, which is how a previous run kills a
    current one and a phantom wedge enters this node's #43885 record.
  * `TestASignalWhileTheWedgeIsRecorded` — a signal must not erase a REAL wedge either.
  * `TestTheHandlerSurvivesEscalation` — an escalating supervisor is ordinary behaviour.
  * `TestHostBenchersRecordAnInterruptedShape` — the orphan bundle that motivated all of this was
    written by `bench_llamacpp.sh`, not by `bench.sh`.

Process hygiene is part of the contract here, not housekeeping: every child runs in its own
session, every session is reaped, and `pkill` is stubbed so the suite itself cannot fire a
box-wide kill on a box whose lab notes say "quiesce before a run".
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from ahl_test import api
from ahl_test.scratch import ScratchRepo

# A guidellm stand-in that can be caught in the act. Same JSON as the stock stub (it imports it),
# but a level named in AHL_STUB_BLOCK touches "<bundle>/.started_c<N>" and then blocks, so the
# test can signal bench.sh at a known point instead of racing it.
BLOCKING_STUB = '''#!/usr/bin/env python3
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guidellm_stub as base


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
    level = int(float(rate))
    blocking = [int(x) for x in os.environ.get("AHL_STUB_BLOCK", "").split(",") if x.strip()]
    match = os.environ.get("AHL_STUB_BLOCK_MATCH", "")
    if level in blocking and (not match or match in os.path.abspath(out)):
        marker = os.path.join(os.path.dirname(os.path.abspath(out)), ".started_c%d" % level)
        with open(marker, "w") as fh:
            fh.write(str(os.getpid()))
        time.sleep(float(os.environ.get("AHL_STUB_BLOCK_SECS", "120")))
        return 0                      # never reached in a test: the signal arrives first
    return base.main(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'''


# A `head` that can be caught in the act. `bench.sh`'s emit_row calls `head -1 "$TSV"`, the FIRST
# of six command boundaries between the old flag-clear and the actual append — the window in which
# a COMPLETED sweep used to lose its row entirely. The stub blocks only on that exact call (two
# argv, the second ending in the journal name), ignores the signal itself (it is addressed to
# bench.sh, not to us) and then answers correctly, so the trap fires at a real command boundary
# INSIDE emit_row and the run is otherwise untouched.
HEAD_STUB = '''#!/usr/bin/env python3
import os, signal, sys, time

argv = sys.argv[1:]
target = os.environ.get("AHL_STUB_HEAD_BLOCK", "")
if target and len(argv) == 2 and argv[0] == "-1" and argv[1].endswith(target):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    with open(os.path.join(os.environ["AHL_STUB_MARKERS"], "head"), "w") as fh:
        fh.write(str(os.getpid()))
    time.sleep(float(os.environ.get("AHL_STUB_HEAD_SECS", "1.0")))
    with open(argv[1]) as fh:
        sys.stdout.write(fh.readline())
    sys.exit(0)
here = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))
for d in os.environ.get("PATH", "").split(":"):
    cand = os.path.join(d, "head")
    if d and os.path.realpath(d) != here and os.access(cand, os.X_OK):
        os.execv(cand, ["head"] + argv)
sys.exit(127)
'''

# `pkill` must never run. The stall-watchdog used to reap its GuideLLM with a box-wide
# `pkill -f 'guidellm benchmark run'`, which on a shared box kills whatever else is benchmarking —
# and, orphaned, kills a LATER run's GuideLLM, whose row then records `status=crash hang@cN`,
# putting a PHANTOM WEDGE into this node's vLLM #43885 record. The stub logs and fails, so the
# test can assert on the absence of the call rather than on the absence of a string in the source.
# It is installed in EVERY test here: the suite itself must not be able to fire a box-wide kill.
PKILL_STUB = """#!/usr/bin/env bash
echo "pkill $*" >> "${AHL_STUB_LOG:-/dev/null}"
exit 1
"""

# A `sleep` that compresses the watchdog's 15 s poll to a few ms, so the watchdog's real code path
# — trip, write the hit file, reap the level — can be EXECUTED in a test rather than asserted
# about. The nominal argument still drives the watchdog's own arithmetic (`z += 15`), so
# STALL_SECS behaves exactly as it does in production.
SLEEP_STUB = """#!/usr/bin/env bash
echo "sleep $*" >> "${AHL_STUB_LOG:-/dev/null}"
exec /bin/sleep "${AHL_STUB_SLEEP_SECS:-0.05}"
"""

# An adapter whose `peakmem` blocks on demand. `peakmem` is the first thing `run_shape` does after
# a level is marked hung, so it is the deterministic point INSIDE the crash-recording window — the
# ~0.5 s in which a signal used to replace the crash row with an interrupted one, skip
# `docker logs > vllm_crash.log` and skip `adapter down`.
ADAPTER_STUB = """#!/usr/bin/env bash
echo "adapter $*" >> "${AHL_STUB_LOG:-/dev/null}"
case "${1:-}" in
  info)    echo 'vllm@0.25.0(img:sha256:deadbeef)' ;;
  health)  exit 0 ;;
  peakmem) if [ -n "${AHL_STUB_PEAKMEM_BLOCK:-}" ]; then
             echo $$ > "$AHL_STUB_MARKERS/peakmem"
             /bin/sleep "${AHL_STUB_PEAKMEM_BLOCK}"
           fi
           echo 'na' ;;
  *)       exit 0 ;;
esac
"""

# A metrics sampler whose `--summary` blocks on demand: that call is the handler's own first
# child, i.e. the window in which the old handler had already run `trap - INT TERM HUP EXIT` and
# an escalating supervisor could kill the script with the row still unwritten.
SAMPLER_STUB = """#!/usr/bin/env bash
echo "metrics_sampler $*" >> "${AHL_STUB_LOG:-/dev/null}"
if [ "${1:-}" = "--summary" ]; then
  if [ -n "${AHL_STUB_SUMMARY_BLOCK:-}" ]; then
    echo $$ > "$AHL_STUB_MARKERS/summary"
    /bin/sleep "${AHL_STUB_SUMMARY_BLOCK}"
  fi
  echo "thermal=na"
fi
exit 0
"""

# A `docker` that reports a wedged engine, so the stall-watchdog's condition is satisfied and its
# trip path executes. `docker logs` without `--since` is the crash-forensics capture.
STALLING_DOCKER_STUB = """#!/usr/bin/env bash
echo "docker $*" >> "${AHL_STUB_LOG:-/dev/null}"
case "${2:-}" in
  --since) echo 'Engine 000: Avg generation throughput: 0.0 tokens/s, Running: 16 reqs, Waiting: 0 reqs' ;;
  *)       echo 'captured engine log' ;;
esac
exit 0
"""


def _write_exec(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
    return path


class InterruptTestCase(unittest.TestCase):
    def setUp(self):
        api.require_file(self, api.REPO_ROOT / "scripts" / "bench.sh", "B2 owns scripts/bench.sh")
        api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0
        self._sessions = []
        self._procs = []
        self.addCleanup(self._reap_sessions)

    # ── process hygiene ───────────────────────────────────────────────────────────────────
    # This box is shared, its own lab notes say "quiesce before a run", and the first version of
    # this module leaked a stall-watchdog per interrupt test — 12 were found running with PPID 1,
    # each polling `docker logs ahl-vllm` every 15 s forever. Every child started here goes into
    # its own session and every session is reaped, whatever the test did or asserted.
    def _reap_sessions(self):
        for pid in self._sessions:
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        for proc in self._procs:                 # and collect them, so nothing is left a zombie
            try:
                proc.wait(timeout=10)
            except (subprocess.TimeoutExpired, OSError):
                pass

    def survivors(self, pid: int) -> list:
        """Every process still alive in `pid`'s session, as `pid cmd` strings."""
        out = subprocess.run(["ps", "-o", "pid=,args=", "-s", str(pid)],
                             capture_output=True, text=True)
        return [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]

    # ── harness ───────────────────────────────────────────────────────────────────────────
    def repo(self, levels=None) -> ScratchRepo:
        self.n += 1
        r = ScratchRepo(self.tmp / f"r{self.n}", levels=levels)
        # `import guidellm_stub` needs the stock stub to be importable, so keep it and add ours.
        (r.root / "bin" / "blocking_stub.py").write_text(BLOCKING_STUB)
        uv = r.root / "bin" / "uv"
        uv.write_text(uv.read_text().replace("guidellm_stub.py", "blocking_stub.py"))
        r.markers = r.root / "markers"
        r.markers.mkdir(exist_ok=True)
        # `pkill` is stubbed unconditionally — see PKILL_STUB.
        _write_exec(r.root / "bin" / "pkill", PKILL_STUB)
        _write_exec(r.root / "scripts" / "metrics_sampler.sh", SAMPLER_STUB)
        _write_exec(r.root / "backends" / "vllm" / "adapter.sh", ADAPTER_STUB)
        return r

    def base_env(self, repo, **extra) -> dict:
        e = repo.env(**extra)
        e["AHL_STUB_LOG"] = str(repo.log)
        e["AHL_STUB_MARKERS"] = str(repo.markers)
        return e

    def start(self, repo, *shapes, **env) -> subprocess.Popen:
        """Popen the REAL bench.sh in its own session, output to files (never pipes: a straggler
        holding the write end of a pipe makes capture_output block after bench.sh has exited)."""
        e = self.base_env(repo, **env)
        out = repo.root / "out.sig"
        err = repo.root / "err.sig"
        argv = ["bash", str(repo.root / "scripts" / "bench.sh"), str(repo.runbook),
                *(shapes or ("chat",))]
        self._fo, self._fe = out.open("w"), err.open("w")
        proc = subprocess.Popen(argv, cwd=str(repo.root), stdout=self._fo, stderr=self._fe,
                                env=e, start_new_session=True)
        proc._ahl_out, proc._ahl_err, proc._ahl_argv = out, err, argv
        self._sessions.append(proc.pid)
        return proc

    def wait_for(self, path: Path, proc, timeout: float = 60.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if path.exists():
                return True
            if proc.poll() is not None:
                return False
            time.sleep(0.02)
        return False

    def finish(self, proc, timeout: float = 60.0) -> subprocess.CompletedProcess:
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:          # pragma: no cover — a hung trap is a failure
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=10)
            self.fail("bench.sh did not exit — the trap hung")
        self._fo.close(); self._fe.close()
        return subprocess.CompletedProcess(proc._ahl_argv, rc,
                                           proc._ahl_out.read_text(), proc._ahl_err.read_text())

    def interrupt(self, repo, *shapes, block_level: int, sig=signal.SIGINT, to_group: bool = False,
                  block_match: str = "", timeout: float = 60.0, **env) -> subprocess.CompletedProcess:
        """Start the real bench.sh, wait until it is provably inside level `block_level`,
        then deliver `sig` to it. Returns once the process is reaped.

        `to_group=True` signals the whole process group — what a terminal Ctrl-C does. The
        default signals bench.sh alone — what a session limit, a supervisor or `kill <pid>`
        does, and the case where bash would defer the trap until the level ended.
        """
        e = self.base_env(repo, **env)
        e["AHL_STUB_BLOCK"] = str(block_level)
        e["AHL_STUB_BLOCK_MATCH"] = block_match   # e.g. "-coder": block only in that shape
        # Bounds any stray if the harness itself is killed — and, just as importantly, bounds how
        # long a MUTANT can hold the suite open. `level_in_foreground` makes bash defer the trap
        # until the level returns, so this value is the per-test cost of that mutation; at 30 s it
        # pushed the mutant suite towards tests/mutate.sh's 900 s cap, where it would have been
        # scored BROKEN (proves nothing) instead of KILLED.
        e["AHL_STUB_BLOCK_SECS"] = "12"
        e["LEVEL_TIMEOUT"] = "300"          # the hard timeout must not fire before we signal
        out = repo.root / "out.sig"
        err = repo.root / "err.sig"
        argv = ["bash", str(repo.root / "scripts" / "bench.sh"), str(repo.runbook),
                *(shapes or ("chat",))]
        with out.open("w") as fo, err.open("w") as fe:
            # Own process group: a test must never signal the whole test runner.
            proc = subprocess.Popen(argv, cwd=str(repo.root), stdout=fo, stderr=fe, env=e,
                                    start_new_session=True)
            self._sessions.append(proc.pid)
            marker = self._await_marker(repo, block_level, proc, timeout, block_match)
            self.assertTrue(marker, "bench.sh never entered the blocking level — harness broken")
            if to_group:
                os.killpg(proc.pid, sig)
            else:
                proc.send_signal(sig)
            try:
                rc = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:      # pragma: no cover — a hung trap is a failure
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)
                self.fail("bench.sh did not exit after the signal — the trap hung")
        # The blocking stub is in bench.sh's process group and outlives it; reap the group so a
        # 120 s sleep does not hold the test open.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        return subprocess.CompletedProcess(argv, rc, out.read_text(), err.read_text())

    def _await_marker(self, repo, level, proc, timeout, block_match=""):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if list((repo.out_dir / "data").glob(f"*{block_match}/.started_c{level}")):
                return True
            if proc.poll() is not None:
                return False
            time.sleep(0.02)
        return False

    def show(self, proc, rows):
        cells = "\n".join(
            f"  [{i}] status={r['status']!r} validity={r['validity']!r} "
            f"c1={r['tps_c1']!r} c16={r['tps_c16']!r} notes={r['notes']!r}"
            for i, r in enumerate(rows))
        return f"rc={proc.returncode}\nrows:\n{cells}\nstderr:\n{proc.stderr[-2500:]}"


class TestAnInterruptedShapeIsRecorded(InterruptTestCase):
    """The gap itself: kill the run between levels and the evidence must reach the journal."""

    def test_sigint_between_levels_writes_a_row(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        rows = repo.rows()
        self.assertEqual(1, len(rows), "the partial shape must leave exactly one row\n"
                                       + self.show(proc, rows))

    def test_the_row_points_at_the_bundle_that_holds_the_evidence(self):
        """The whole failure mode is evidence on disk that nothing references."""
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        row = repo.rows()[-1]
        bundles = [p.name for p in (repo.out_dir / "data").iterdir() if p.is_dir()]
        self.assertEqual(1, len(bundles), self.show(proc, [row]))
        self.assertTrue(row["data"].endswith(bundles[0]),
                        f"data={row['data']!r} must reference {bundles[0]!r}")
        self.assertEqual(bundles[0], row["run_id"], self.show(proc, [row]))
        self.assertTrue((repo.out_dir / "data" / bundles[0] / "level_c1.json").exists(),
                        "the c1 evidence the row now makes reachable")

    def test_the_completed_level_keeps_its_number(self):
        repo = self.repo({1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": 200.0}})
        proc = self.interrupt(repo, block_level=16)
        row = repo.rows()[-1]
        self.assertEqual("20", row["tps_c1"], self.show(proc, [row]))
        self.assertEqual("c1:41/0/0", row["req_counts"],
                         "the counts must come from the level JSON that survived\n"
                         + self.show(proc, [row]))

    def test_the_interrupted_level_is_na_and_never_hang(self):
        """`hang` is the wedge sentinel and feeds this node's crash record (vLLM #43885).
        An operator's Ctrl-C is not a wedge."""
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        row = repo.rows()[-1]
        self.assertEqual("na", row["tps_c16"], self.show(proc, [row]))
        self.assertNotIn("hang", row["tps_c16"])
        self.assertNotEqual("crash", row["status"], self.show(proc, [row]))

    def test_the_status_never_claims_a_completed_measurement(self):
        """§6: `measured` means the invariants passed on a real sweep. This is not one."""
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        row = repo.rows()[-1]
        self.assertEqual("suspect", row["status"], self.show(proc, [row]))

    def test_the_notes_name_the_interruption_and_the_level(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        row = repo.rows()[-1]
        self.assertIn("interrupted", row["notes"], self.show(proc, [row]))
        self.assertIn("@c16", row["notes"], self.show(proc, [row]))

    def test_the_operator_status_is_not_laundered_into_the_partial_row(self):
        """`STATUS=keep` is an adjudication of a finished run. An interrupted run has none."""
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16, STATUS="keep")
        row = repo.rows()[-1]
        self.assertEqual("suspect", row["status"], self.show(proc, [row]))

    def test_the_exit_status_is_the_conventional_signal_code(self):
        """128+N, not 4: "written but not citable, continue" is the wrong thing to tell a
        caller whose operator just pressed Ctrl-C."""
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        # Python reports "died of signal N" as -N; a shell reports the same thing as 128+N.
        self.assertEqual(-int(signal.SIGINT), proc.returncode, proc.stderr[-2000:])

    def test_sigterm_is_recorded_too(self):
        """A session limit or `kill` is SIGTERM, not SIGINT — and it is delivered to the script
        alone, not to the process group. That is the case where bash would defer the trap until
        the level finished (up to LEVEL_TIMEOUT), long after a supervisor's SIGKILL. run_level
        backgrounds GuideLLM and `wait`s precisely so this arrives promptly."""
        repo = self.repo()
        t0 = time.time()
        proc = self.interrupt(repo, block_level=16, sig=signal.SIGTERM)
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("suspect", rows[-1]["status"], self.show(proc, rows))
        self.assertEqual(-int(signal.SIGTERM), proc.returncode)
        self.assertLess(time.time() - t0, 7,
                        "the handler must not wait out the blocking level (12 s)")

    def test_a_group_wide_ctrl_c_is_recorded_too(self):
        """What a terminal Ctrl-C actually does: SIGINT to the whole foreground group, so
        GuideLLM dies alongside the script."""
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16, to_group=True)
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("suspect", rows[-1]["status"], self.show(proc, rows))
        self.assertIn("interrupted", rows[-1]["notes"], self.show(proc, rows))


class TestInterruptedBeforeAnyLevelLanded(InterruptTestCase):
    """Killed inside the FIRST level: there is no evidence, and the row must say so rather
    than inventing one. Contract §3/A5: `na` is "could not be evaluated", never `ok`."""

    def test_a_row_still_appears(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=1)
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))

    def test_it_carries_no_numbers_and_is_not_ok(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=1)
        row = repo.rows()[-1]
        for col in ("tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32", "peak_gb"):
            self.assertEqual("na", row[col], f"{col}\n" + self.show(proc, [row]))
        self.assertEqual("na", row["validity"], self.show(proc, [row]))
        self.assertIn(row["status"], ("suspect", "void"), self.show(proc, [row]))


class TestNoDuplicateRow(InterruptTestCase):
    """The other half of the requirement: closing the hole must not put a second row on a run
    that finishes normally. A duplicate corrupts every median taken over the journal."""

    def test_a_normal_run_writes_exactly_one_row_per_shape(self):
        repo = self.repo()
        proc = repo.bench("chat")
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("measured", rows[0]["status"], self.show(proc, rows))
        self.assertEqual(0, proc.returncode, self.show(proc, rows))

    def test_two_shapes_write_two_rows_and_the_trap_adds_none(self):
        repo = self.repo()
        proc = repo.bench("chat", "coder")
        rows = repo.rows()
        self.assertEqual(2, len(rows), self.show(proc, rows))
        self.assertEqual(["chat(512/256)", "coder(4096/1024)"], [r["shape"] for r in rows],
                         self.show(proc, rows))
        self.assertEqual(["measured", "measured"], [r["status"] for r in rows],
                         self.show(proc, rows))

    def test_a_crash_row_is_not_duplicated_by_the_trap(self):
        """The hang path tears the container down and returns 3 — it already writes its row."""
        repo = self.repo({1: {"ok": 41, "tps": 20.0}, 16: None})
        proc = repo.bench("chat")
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("crash", rows[0]["status"], self.show(proc, rows))
        self.assertEqual(3, proc.returncode, self.show(proc, rows))

    def test_a_completed_shape_before_the_interrupted_one_keeps_its_own_row(self):
        """chat finishes, coder is interrupted: two rows, and only the second is partial."""
        repo = self.repo()
        proc = self.interrupt(repo, "chat", "coder", block_level=16, block_match="-coder")
        rows = repo.rows()
        self.assertEqual(2, len(rows), self.show(proc, rows))
        self.assertEqual("measured", rows[0]["status"], self.show(proc, rows))
        self.assertEqual("chat(512/256)", rows[0]["shape"], self.show(proc, rows))
        self.assertEqual("suspect", rows[1]["status"], self.show(proc, rows))
        self.assertEqual("coder(4096/1024)", rows[1]["shape"], self.show(proc, rows))
        self.assertNotEqual(rows[0]["run_id"], rows[1]["run_id"])


class TestTheRowIsAContractRow(InterruptTestCase):
    """A partial row is still a §2 row: 23 columns, no empties, no tabs, and the provenance
    that IS known must be present (an interrupted run knows its config just as well)."""

    def test_the_partial_row_has_the_contract_columns_and_no_empty_cell(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        raw = repo.tsv.read_text().splitlines()
        self.assertEqual(api.CONTRACT_COLUMNS, raw[0].split("\t"))
        cells = raw[-1].split("\t")
        self.assertEqual(len(api.CONTRACT_COLUMNS), len(cells), self.show(proc, repo.rows()))
        self.assertNotIn("", cells, "contract §2: no value is ever empty")

    def test_the_known_provenance_is_recorded(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16)
        row = repo.rows()[-1]
        self.assertEqual("Org/Model", row["model"], self.show(proc, [row]))
        self.assertNotEqual("na", row["config_hash"], "the runbook hash is known — record it")
        self.assertNotEqual("na", row["script"], self.show(proc, [row]))
        self.assertIn("levels=1|16", row["knobs"], self.show(proc, [row]))


class ReconcileTestCase(unittest.TestCase):
    """`scripts/reconcile_bundles.py` — the recovery half, for evidence already stranded.

    The trap cannot help after SIGKILL, an OOM-kill or a power cut, and it cannot help the
    orphans already on disk. These tests build a results tree by hand and run the real tool.
    """

    def setUp(self):
        self.tool = api.REPO_ROOT / "scripts" / "reconcile_bundles.py"
        api.require_file(self, self.tool, "B2 owns scripts/reconcile_bundles.py")
        api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.results = self.root / "results"
        self.model_dir = self.results / "gb10-test" / "Org" / "Model"
        (self.model_dir / "data").mkdir(parents=True)
        self.tsv = self.model_dir / "results.tsv"

    # ── fixtures ──────────────────────────────────────────────────────────────────────────
    def bundle(self, run_id: str, levels: dict, age_s: float = 7200.0) -> Path:
        b = api.write_bundle(self.model_dir / "data" / run_id, levels)
        old = time.time() - age_s
        for p in list(b.rglob("*")) + [b]:
            os.utime(p, (old, old))
        return b

    def journal(self, *rows):
        cols = api.CONTRACT_COLUMNS
        lines = ["\t".join(cols)]
        for r in rows:
            base = {c: "na" for c in cols}
            base.update(r)
            lines.append("\t".join(base[c] for c in cols))
        self.tsv.write_text("\n".join(lines) + "\n")

    def run_tool(self, *args, timeout: int = 120) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.tool), "--results", str(self.results),
                               *args], capture_output=True, text=True, timeout=timeout)

    def rows(self) -> list:
        return api.read_tsv(self.tsv) if self.tsv.exists() else []

    # ── the gap ───────────────────────────────────────────────────────────────────────────
    def test_a_dry_run_finds_the_orphan_and_writes_nothing(self):
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal()
        before = self.tsv.read_text()
        proc = self.run_tool()
        self.assertIn("20260101-000000-chat", proc.stdout, proc.stdout + proc.stderr)
        self.assertEqual(before, self.tsv.read_text(), "a dry run must not touch the journal")
        self.assertEqual(4, proc.returncode, proc.stdout + proc.stderr)

    def test_write_appends_one_row_that_carries_the_evidence(self):
        self.bundle("20260101-000000-chat",
                    {1: api.level_json(41, tps=20.0, rate=1),
                     16: api.level_json(118, incomplete=4, tps=200.0, rate=16)})
        self.journal()
        proc = self.run_tool("--write")
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        rows = self.rows()
        self.assertEqual(1, len(rows), proc.stdout)
        row = rows[0]
        self.assertEqual("20260101-000000-chat", row["run_id"])
        self.assertEqual("c1:41/0/0;c16:118/4/0", row["req_counts"], str(row))
        self.assertEqual("20", row["tps_c1"], str(row))
        self.assertEqual("200", row["tps_c16"], str(row))
        self.assertEqual("Org/Model", row["model"], str(row))
        self.assertTrue(row["data"].endswith("data/20260101-000000-chat"), str(row))

    def test_the_row_is_marked_reconstructed_and_never_measured(self):
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal()
        self.run_tool("--write")
        row = self.rows()[0]
        self.assertEqual("suspect", row["status"], str(row))
        self.assertIn("RECONSTRUCTED", row["notes"], str(row))
        self.assertIn("reconcile_bundles.py", row["notes"], str(row))

    def test_what_the_bundle_cannot_know_is_na_and_the_row_says_so(self):
        """§4's rule about a missing bandwidth number, applied to provenance: never guess."""
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal()
        self.run_tool("--write")
        row = self.rows()[0]
        for col in ("commit", "config_hash", "script", "backend", "load_s", "peak_gb"):
            self.assertEqual("na", row[col], f"{col} is not recoverable from a bundle: {row}")
            self.assertIn(col, row["notes"], f"the notes must name {col} as unrecoverable")
        # ... while what the bundle DOES record is recovered rather than left blank.
        self.assertEqual("180", row["max_s"], str(row))
        self.assertEqual("42", row["seed"], str(row))
        self.assertIn("gllm=0.6.0", row["knobs"], str(row))
        self.assertIn("stall=na", row["knobs"], "an unrecorded knob is `na`, not the default")

    def test_a_level_that_started_and_left_no_json_is_reported_not_scored(self):
        """Both real orphans on this node look like tidy sweeps until you notice a `level_cN.log`
        with no sibling JSON: the run was cut short in that level. No measurement to score, but
        "this sweep did not finish" is exactly what a reconstructed row must not silently lose."""
        b = self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        (b / "level_c16.log").write_text("guidellm started c16 and never landed\n")
        old = time.time() - 7200
        os.utime(b / "level_c16.log", (old, old))
        os.utime(b, (old, old))          # writing the log freshened the directory mtime too
        self.journal()
        proc = self.run_tool("--write")
        row = self.rows()[0]
        self.assertEqual("na", row["tps_c16"], str(row))
        self.assertNotIn("c16", row["req_counts"], "an unfinished level is not scored")
        self.assertIn("c16", row["notes"].split("did not finish:")[-1], str(row))
        self.assertIn("started", row["notes"], proc.stdout)

    def test_fatal_evidence_makes_the_reconstructed_row_void(self):
        """The library's verdict still decides: a 2-request level is `no_data`, i.e. not data."""
        self.bundle("20260101-000000-chat", {16: api.level_json(2, incomplete=31, tps=256.19,
                                                                rate=16)})
        self.journal()
        self.run_tool("--write")
        row = self.rows()[0]
        self.assertIn("no_data", row["validity"], str(row))
        self.assertEqual("void", row["status"], str(row))

    def test_it_is_idempotent_and_never_rewrites_an_existing_row(self):
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal({"run_id": "20251231-235959-chat", "status": "measured",
                      "data": "results/gb10-test/Org/Model/data/20251231-235959-chat"})
        published = self.tsv.read_text().splitlines()[1]
        first = self.run_tool("--write")
        self.assertEqual(0, first.returncode, first.stdout + first.stderr)
        self.assertEqual(2, len(self.rows()))
        self.assertIn(published, self.tsv.read_text(), "a published row must survive byte-exact")
        second = self.run_tool()
        self.assertEqual(0, second.returncode, second.stdout + second.stderr)
        self.assertIn("nothing to reconcile", second.stdout)
        self.assertEqual(2, len(self.rows()), "a reconciled bundle is no longer an orphan")

    def test_a_bundle_a_row_already_references_is_left_alone(self):
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal({"run_id": "20260101-000000-chat", "status": "measured",
                      "data": "results/gb10-test/Org/Model/data/20260101-000000-chat"})
        proc = self.run_tool("--write")
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertEqual(1, len(self.rows()), proc.stdout)

    # ── the safety rails ──────────────────────────────────────────────────────────────────
    def test_a_bundle_still_being_written_is_not_claimed(self):
        """A bench may be running on this box right now; its row is pending, not missing."""
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)}, age_s=5)
        self.journal()
        proc = self.run_tool("--write")
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertEqual([], self.rows(), "an in-flight bundle must not be reconciled")
        self.assertIn("in flight", proc.stdout)

    def test_an_empty_bundle_holds_no_measurement_and_is_not_invented(self):
        (self.model_dir / "data" / "20260101-000000-chat").mkdir()
        old = time.time() - 7200
        os.utime(self.model_dir / "data" / "20260101-000000-chat", (old, old))
        self.journal()
        proc = self.run_tool("--write")
        self.assertEqual([], self.rows(), proc.stdout)
        self.assertIn("nothing to recover", proc.stdout)

    def test_an_eval_bundle_is_not_reconstructed_into_the_throughput_journal(self):
        """`-eval` is Gate 2 (accuracy.tsv, scripts/eval_validity.py) — different rules."""
        d = self.model_dir / "data" / "20260101-000000-eval"
        (d / "model").mkdir(parents=True)
        (d / "model" / "results_2026.json").write_text("{}")
        old = time.time() - 7200
        for p in list(d.rglob("*")) + [d]:
            os.utime(p, (old, old))
        self.journal()
        proc = self.run_tool("--write")
        self.assertEqual([], self.rows(), proc.stdout)
        self.assertIn("Gate-2", proc.stdout)

    def test_a_journal_missing_its_final_newline_is_not_corrupted(self):
        """Appending onto a truncated last line would edit a published row instead of adding
        one — the single thing this tool must never do."""
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal({"run_id": "20251231-235959-chat", "status": "measured"})
        self.tsv.write_text(self.tsv.read_text().rstrip("\n"))
        published = self.tsv.read_text().splitlines()[1]
        proc = self.run_tool("--write")
        self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertIn(published, self.tsv.read_text().splitlines(),
                      "the published row must still be its own line")
        self.assertEqual(2, len(self.rows()), self.tsv.read_text())

    def test_an_unreadable_journal_claims_nothing_rather_than_everything(self):
        """Fail closed. If the journal cannot be read, every published row looks like an orphan
        and `--write` would duplicate the whole campaign."""
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.tsv.write_bytes(b"\xff\xfe not a tsv \x00\x80\n")
        before = self.tsv.read_bytes()
        proc = self.run_tool("--write")
        self.assertEqual(1, proc.returncode, proc.stdout + proc.stderr)
        self.assertEqual(before, self.tsv.read_bytes(), "the journal must be untouched")
        self.assertIn("could not be read", proc.stdout, proc.stdout + proc.stderr)

    def test_a_task_scoped_eval_bundle_is_still_gate_2(self):
        """`_RUN_ID` demanded `[A-Za-z0-9_]+`, so `<date>-<time>-eval-mmlu` did not parse at all:
        the `shape == "eval"` test could not fire and the bundle would have been reconstructed
        into the THROUGHPUT journal with `shape=na`. The kind is the FIRST token of the suffix."""
        self.bundle("20260101-000000-eval-mmlu", {1: api.level_json(41, tps=20.0, rate=1)})
        self.journal()
        proc = self.run_tool("--write", "--include-empty")
        self.assertEqual([], self.rows(),
                         "a Gate-2 bundle must never become a throughput row\n" + proc.stdout)
        self.assertIn("Gate-2", proc.stdout, proc.stdout + proc.stderr)

    def test_a_private_eval_bundle_is_not_a_throughput_row_either(self):
        """`eval_private.sh` writes `-private` run-ids. Safe today only because those bundles hold
        no `level_c*.json` — and `--include-empty` exists precisely to write bundles that hold
        none."""
        d = self.model_dir / "data" / "20260101-000000-private"
        d.mkdir(parents=True)
        old = time.time() - 7200
        os.utime(d, (old, old))
        self.journal()
        proc = self.run_tool("--write", "--include-empty")
        self.assertEqual([], self.rows(), proc.stdout)

    def test_a_level_the_row_has_no_cell_for_is_not_affirmed_as_ok(self):
        """`results.tsv` has five tps columns. A `level_c7.json` bundle used to score
        `validity=ok` while every `tps_c*` read `na` — an affirmative "the invariants passed" over
        a number the row does not contain, i.e. contract A5 read backwards."""
        self.bundle("20260101-000000-chat", {7: api.level_json(41, tps=20.0, rate=7)})
        self.journal()
        proc = self.run_tool("--write")
        rows = self.rows()
        self.assertEqual(1, len(rows), proc.stdout)
        row = rows[0]
        for col in ("tps_c1", "tps_c4", "tps_c8", "tps_c16", "tps_c32"):
            self.assertEqual("na", row[col], str(row))
        self.assertEqual("na", row["validity"],
                         "no cell, no verdict — `na` is 'could not be evaluated', never `ok`\n"
                         + str(row))
        self.assertEqual("suspect", row["status"], str(row))
        self.assertIn("c7", row["notes"], str(row))

    def test_an_off_grid_level_beside_a_real_one_is_kept_as_evidence_and_explained(self):
        """The mixed case is not the defect — a `@c7`-tagged verdict cannot touch a c1 or c16
        citation (contract §3: gate on the level you cite), and dropping the counts would throw
        evidence away. What the row must not do is stay silent about a level it has no cell for."""
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1),
                                             7: api.level_json(2, tps=99999.0, rate=7)})
        self.journal()
        self.run_tool("--write")
        row = self.rows()[0]
        self.assertEqual("20", row["tps_c1"], str(row))
        self.assertIn("c1:41", row["req_counts"], str(row))
        self.assertIn("c7", row["req_counts"], "the evidence is real and stays in the row")
        for col in ("tps_c4", "tps_c8", "tps_c16", "tps_c32"):
            self.assertEqual("na", row[col], str(row))
        self.assertIn("c7", row["notes"].split("no cell for them")[-1],
                      "the row must say which levels it has no cell for\n" + str(row))

    def test_it_refuses_a_pre_migration_journal_rather_than_misaligning_it(self):
        self.bundle("20260101-000000-chat", {1: api.level_json(41, tps=20.0, rate=1)})
        self.tsv.write_text("\t".join(api.CONTRACT_COLUMNS[:20]) + "\n")
        before = self.tsv.read_text()
        proc = self.run_tool("--write")
        self.assertNotEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertEqual(before, self.tsv.read_text(), "a mismatched journal must be untouched")
        self.assertIn("migrate", (proc.stdout + proc.stderr).lower())


class TestKilledRunIsRecoverable(InterruptTestCase):
    """The two halves together, on the one case the trap CANNOT cover.

    SIGKILL is untrappable — so is a kernel OOM-kill and a power cut. bench.sh leaves the
    bundle and no row; `reconcile_bundles.py` is what makes that evidence reachable again.
    """

    def test_sigkill_leaves_an_orphan_that_reconcile_recovers(self):
        repo = self.repo()
        proc = self.interrupt(repo, block_level=16, sig=signal.SIGKILL)
        self.assertEqual([], repo.rows(), "SIGKILL cannot be trapped — no row is expected")
        bundles = [p for p in (repo.out_dir / "data").iterdir() if p.is_dir()]
        self.assertEqual(1, len(bundles))
        self.assertTrue((bundles[0] / "level_c1.json").exists(), "the c1 evidence survived")

        tool = api.REPO_ROOT / "scripts" / "reconcile_bundles.py"
        api.require_file(self, tool, "B2 owns scripts/reconcile_bundles.py")
        rec = subprocess.run([sys.executable, str(tool), "--results", str(repo.root / "results"),
                              "--min-age", "0", "--write"],
                             capture_output=True, text=True, timeout=120)
        self.assertEqual(0, rec.returncode, rec.stdout + rec.stderr)
        rows = repo.rows()
        self.assertEqual(1, len(rows), rec.stdout)
        self.assertEqual(bundles[0].name, rows[0]["run_id"], str(rows[0]))
        self.assertEqual("c1:41/0/0", rows[0]["req_counts"], str(rows[0]))
        self.assertEqual("suspect", rows[0]["status"], str(rows[0]))
        self.assertIn("RECONSTRUCTED", rows[0]["notes"], str(rows[0]))


class TestTheWriteIsTheAtomicUnit(InterruptTestCase):
    """`exactly once` has to hold in the ZERO direction too.

    The shipped design cleared `SHAPE_IN_FLIGHT` immediately BEFORE calling `emit_row`. That did
    make a second row impossible — and made the FIRST row skippable. Between the clear and the
    `printf … >> "$TSV"` there are six command boundaries (`head`, `awk`, `printf|awk`, the header
    `echo`, two `tsv_safe` substitutions); bash runs a trap at a command boundary; the handler
    found the flag already down, returned, and re-raised. A **fully completed sweep** then left its
    bundle on disk and nothing in the journal, while stderr announced that it was recording the
    partial shape. `reconcile_bundles.py` would later re-import that run as `suspect`: a good
    measurement permanently downgraded.

    The `head` stub makes the window deterministic instead of ~6 ms wide.
    """

    def signalled_mid_write(self, sig=signal.SIGTERM, **env):
        repo = self.repo()
        _write_exec(repo.root / "bin" / "head", HEAD_STUB)
        # emit_row only reads the header when the journal already exists.
        repo.tsv.write_text("\t".join(api.CONTRACT_COLUMNS) + "\n")
        proc = self.start(repo, "chat", AHL_STUB_HEAD_BLOCK="results.tsv",
                          AHL_STUB_HEAD_SECS="1.0", **env)
        self.assertTrue(self.wait_for(repo.markers / "head", proc),
                        "bench.sh never reached emit_row's header check — harness broken")
        # bench.sh ALONE, not the group: the stub is one half of `head -1 "$TSV" | awk …`, and a
        # group signal would kill `awk`, breaking the pipe and turning this into a schema-mismatch
        # test instead. bash defers the trap to the end of that command substitution — which is
        # exactly the boundary INSIDE emit_row that this test exists to cover.
        proc.send_signal(sig)
        return repo, self.finish(proc)

    def test_a_completed_sweep_signalled_inside_emit_row_still_lands_its_row(self):
        repo, proc = self.signalled_mid_write()
        rows = repo.rows()
        self.assertEqual(1, len(rows),
                         "the sweep FINISHED — its row must not be lost to a signal that arrived "
                         "while the row was being appended\n" + self.show(proc, rows))

    def test_and_that_row_says_measured_not_interrupted(self):
        """Not merely "a row": the right row. A completed sweep downgraded to `suspect` is the
        same evidence loss one step further on, and `reconcile` cannot undo it."""
        repo, proc = self.signalled_mid_write()
        row = repo.rows()[-1]
        self.assertEqual("measured", row["status"], self.show(proc, [row]))
        self.assertNotIn("interrupted", row["notes"], self.show(proc, [row]))
        self.assertEqual("20", row["tps_c1"], self.show(proc, [row]))

    def test_the_signal_is_still_honoured_after_the_row_lands(self):
        """Deferred, not swallowed: the caller must still see its Ctrl-C as 128+N."""
        _, proc = self.signalled_mid_write(sig=signal.SIGTERM)
        self.assertEqual(-int(signal.SIGTERM), proc.returncode, proc.stderr[-2000:])

    def test_it_is_still_exactly_one_row_and_never_two(self):
        repo, proc = self.signalled_mid_write(sig=signal.SIGINT)
        self.assertEqual(1, len(repo.rows()), self.show(proc, repo.rows()))

    def test_a_second_shape_signalled_mid_write_keeps_the_first_shape_intact(self):
        """chat completes normally, coder is signalled inside its own append."""
        repo = self.repo()
        _write_exec(repo.root / "bin" / "head", HEAD_STUB)
        repo.tsv.write_text("\t".join(api.CONTRACT_COLUMNS) + "\n")
        proc = self.start(repo, "chat", "coder", AHL_STUB_HEAD_BLOCK="results.tsv",
                          AHL_STUB_HEAD_SECS="1.0")
        # The chat shape's own append trips the marker first; clear it and wait for coder's.
        self.assertTrue(self.wait_for(repo.markers / "head", proc))
        (repo.markers / "head").unlink()
        self.assertTrue(self.wait_for(repo.markers / "head", proc))
        proc.send_signal(signal.SIGTERM)
        done = self.finish(proc)
        rows = repo.rows()
        self.assertEqual(2, len(rows), self.show(done, rows))
        self.assertEqual(["chat(512/256)", "coder(4096/1024)"], [r["shape"] for r in rows],
                         self.show(done, rows))
        self.assertEqual(["measured", "measured"], [r["status"] for r in rows],
                         self.show(done, rows))


class TestNoProcessOutlivesTheRun(InterruptTestCase):
    """The stall-watchdog must not survive its bench — the finding that had already contaminated
    this box.

    `run_level` held the watchdog pid in a `local wd`, killed only on the normal path;
    `emit_interrupted_row` reaped the level and the sampler and never it. An interrupt therefore
    orphaned a watchdog with PPID 1, which kept polling `docker logs ahl-vllm` every 15 s forever
    (the interrupt path deliberately does not `adapter down`, so the container keeps serving and
    its loop never ends). The first time a LATER run genuinely stalled, that orphan fired its kill
    at the CURRENT run's GuideLLM — and the current run wrote `status=crash notes=hang@cN`, a
    phantom wedge in the record that feeds research/upstream/vllm-43885-gb10-wedge.md.
    """

    def assert_session_empty(self, proc, note="", settle: float = 5.0):
        """Nothing may still be running in the child's session. A short settling window is
        allowed — SIGTERM delivery and reaping are asynchronous — but not an open-ended one: the
        orphan this catches lives for as long as the container serves."""
        deadline = time.time() + settle
        left = self.survivors(proc.pid)
        while left and time.time() < deadline:
            time.sleep(0.05)
            left = self.survivors(proc.pid)
        self.assertEqual([], left,
                         "processes outlived the bench: %s\n%s" % (left, note))

    def test_a_normal_run_leaves_nothing_behind(self):
        repo = self.repo()
        proc = self.start(repo, "chat")
        done = self.finish(proc)
        self.assertEqual(0, done.returncode, done.stderr[-2000:])
        self.assert_session_empty(proc, done.stderr[-1500:])

    def test_an_interrupted_run_leaves_nothing_behind(self):
        """The case that leaked: the handler must reap the watchdog it never used to know about."""
        repo = self.repo()
        e = dict(AHL_STUB_BLOCK="16", AHL_STUB_BLOCK_SECS="12", LEVEL_TIMEOUT="300")
        proc = self.start(repo, "chat", **e)
        self.assertTrue(self.wait_for(repo.out_dir / "data", proc))
        started = None
        deadline = time.time() + 60
        while time.time() < deadline and started is None:
            hits = list((repo.out_dir / "data").glob("*/.started_c16"))
            started = hits[0] if hits else None
            time.sleep(0.02)
        self.assertIsNotNone(started, "bench.sh never entered c16 — harness broken")
        proc.send_signal(signal.SIGTERM)
        done = self.finish(proc)
        self.assertEqual(1, len(repo.rows()), self.show(done, repo.rows()))
        self.assert_session_empty(proc, done.stderr[-1500:])

    def test_bench_never_reaches_for_a_box_wide_pkill(self):
        """A `pkill -f 'guidellm benchmark run'` matches every bench on the box, not this one."""
        repo = self.repo()
        proc = self.start(repo, "chat")
        self.finish(proc)
        self.assertNotIn("pkill", repo.calls(),
                         "a pattern kill reaches other agents' runs:\n" + repo.calls())


class TestTheWatchdogTripsScoped(InterruptTestCase):
    """The watchdog's own trip path, EXECUTED. `sleep` is compressed so its 15 s poll is a few ms;
    everything else — the docker-log condition, STALL_SECS, the kill, the crash row — is real."""

    def stalled_run(self):
        repo = self.repo({1: {"ok": 41, "tps": 20.0}})
        _write_exec(repo.root / "bin" / "sleep", SLEEP_STUB)
        _write_exec(repo.root / "bin" / "docker", STALLING_DOCKER_STUB)
        proc = self.start(repo, "chat", AHL_STUB_BLOCK="1", AHL_STUB_BLOCK_SECS="30",
                          STALL_SECS="15", LEVEL_TIMEOUT="300", AHL_STUB_SLEEP_SECS="0.05")
        return repo, self.finish(proc, timeout=90)

    def test_a_stall_becomes_a_crash_row_at_the_level_that_stalled(self):
        repo, proc = self.stalled_run()
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("crash", rows[0]["status"], self.show(proc, rows))
        self.assertEqual("hang", rows[0]["tps_c1"], self.show(proc, rows))
        self.assertIn("hang@c1", rows[0]["notes"], self.show(proc, rows))
        self.assertEqual(3, proc.returncode, self.show(proc, rows))

    def test_the_kill_is_scoped_to_the_level_it_guards(self):
        repo, proc = self.stalled_run()
        self.assertNotIn("pkill", repo.calls(),
                         "the watchdog must reap its own level by pid, never by pattern:\n"
                         + repo.calls())

    def test_the_wedge_still_produces_its_forensics_and_teardown(self):
        repo, proc = self.stalled_run()
        bundles = [p for p in (repo.out_dir / "data").iterdir() if p.is_dir()]
        self.assertTrue((bundles[0] / "vllm_crash.log").exists(),
                        "vLLM #43885's protocol asks for the engine log")
        self.assertIn("adapter down", repo.calls(), repo.calls())


class TestASignalWhileTheWedgeIsRecorded(InterruptTestCase):
    """A signal must not erase a real wedge.

    `SHAPE_IN_FLIGHT` stays up for ~0.5 s after a level is marked hung — peakmem, the thermal
    summary, knobs, validity. A signal in that window used to write the interrupted row INSTEAD of
    the crash row: `status=crash` was replaced, `docker logs > vllm_crash.log` was skipped (losing
    the artefact the #43885 protocol demands), and `adapter down` was skipped, leaving a wedged
    container holding the GPU. bench.sh argues carefully that a Ctrl-C must not ENTER the wedge
    record; a wedge silently LEAVING it was unguarded.
    """

    def wedge_then_signal(self):
        repo = self.repo({1: {"ok": 41, "tps": 20.0}, 16: None})
        _write_exec(repo.root / "bin" / "docker", STALLING_DOCKER_STUB)
        proc = self.start(repo, "chat", AHL_STUB_PEAKMEM_BLOCK="5")
        self.assertTrue(self.wait_for(repo.markers / "peakmem", proc),
                        "bench.sh never reached the post-crash peakmem probe — harness broken")
        # A terminal Ctrl-C: the whole foreground group, so the blocking probe dies with it and
        # bash reaches the trap at that boundary.
        os.killpg(proc.pid, signal.SIGINT)
        return repo, self.finish(proc)

    def test_the_row_is_still_a_crash_row(self):
        repo, proc = self.wedge_then_signal()
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("crash", rows[0]["status"],
                         "the wedge was already detected — a signal must not downgrade it to an "
                         "operator interruption\n" + self.show(proc, rows))

    def test_the_row_still_names_the_level_that_wedged(self):
        repo, proc = self.wedge_then_signal()
        row = repo.rows()[-1]
        self.assertIn("hang@c16", row["notes"], self.show(proc, [row]))
        self.assertEqual("hang", row["tps_c16"], self.show(proc, [row]))
        self.assertEqual("20", row["tps_c1"], "the completed level keeps its number")

    def test_the_forensics_and_the_teardown_still_happen(self):
        repo, proc = self.wedge_then_signal()
        bundles = [p for p in (repo.out_dir / "data").iterdir() if p.is_dir()]
        self.assertTrue((bundles[0] / "vllm_crash.log").exists(),
                        "the engine log is the artefact #43885 asks for\n" + proc.stderr[-1500:])
        self.assertIn("adapter down", repo.calls(),
                      "a wedged container must not be left holding the GPU\n" + repo.calls())


class TestTheHandlerSurvivesEscalation(InterruptTestCase):
    """A supervisor escalating is ordinary behaviour, not an insistent human.

    The first handler ran `trap - INT TERM HUP EXIT` on entry and then spent several hundred ms in
    `metrics_sampler --summary`, `ahl_knobs` and `ahl_validity` (the last through `uv`, which can
    block on a lock the live bench holds). SIGINT-then-SIGTERM, and SIGTERM twice, both killed the
    script with the row unwritten.
    """

    def escalate(self, first, second):
        repo = self.repo()
        proc = self.start(repo, "chat", AHL_STUB_BLOCK="16", AHL_STUB_BLOCK_SECS="12",
                          LEVEL_TIMEOUT="300", AHL_STUB_SUMMARY_BLOCK="2")
        deadline = time.time() + 60
        while time.time() < deadline:
            if list((repo.out_dir / "data").glob("*/.started_c16")):
                break
            time.sleep(0.02)
        proc.send_signal(first)
        self.assertTrue(self.wait_for(repo.markers / "summary", proc, timeout=30),
                        "the handler never started its bounded work — harness broken")
        proc.send_signal(second)              # the escalation, mid-handler
        return repo, self.finish(proc, timeout=90)

    def test_sigint_then_sigterm_still_leaves_the_row(self):
        repo, proc = self.escalate(signal.SIGINT, signal.SIGTERM)
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("suspect", rows[0]["status"], self.show(proc, rows))

    def test_sigterm_twice_still_leaves_the_row(self):
        repo, proc = self.escalate(signal.SIGTERM, signal.SIGTERM)
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("suspect", rows[0]["status"], self.show(proc, rows))

    def test_an_untrapped_signal_still_leaves_a_row_and_the_note_is_honest(self):
        """SIGUSR1 is not trapped; its default action still runs the EXIT trap. The note used to
        read `interrupted(abort rc=0)`, which reads like a clean exit that somehow left a partial
        row."""
        repo = self.repo()
        proc = self.start(repo, "chat", AHL_STUB_BLOCK="16", AHL_STUB_BLOCK_SECS="12",
                          LEVEL_TIMEOUT="300")
        deadline = time.time() + 60
        while time.time() < deadline:
            if list((repo.out_dir / "data").glob("*/.started_c16")):
                break
            time.sleep(0.02)
        proc.send_signal(signal.SIGUSR1)
        done = self.finish(proc, timeout=60)
        rows = repo.rows()
        self.assertEqual(1, len(rows), self.show(done, rows))
        self.assertIn("unfinished", rows[0]["notes"],
                      "`rc=0` in an EXIT-trap note must not imply a clean finish\n"
                      + self.show(done, rows))
        self.assertIn("partial shape", rows[0]["notes"], self.show(done, rows))


# ══════════════════════════════════════════════════════════════════════════════════════════════
# The HOST-PROCESS benchers (contract's `ds4` / `llamacpp` path)
# ══════════════════════════════════════════════════════════════════════════════════════════════
FAKE_SERVER = """#!/usr/bin/env bash
# Stands in for a served llama-server/ds4-server: it only has to exist, carry a plausible argv
# that `pgrep -f` matches and `scripts/lib/hostcfg.sh` can hash, and stay alive. Deliberately NOT
# `exec`: the bencher finds its engine by matching the process's own cmdline, and exec would
# replace it with `sleep`.
/bin/sleep 600
"""


class HostBenchTestCase(InterruptTestCase):
    """`bench_ds4.sh` / `bench_llamacpp.sh` are the benchers that produced the evidence: the
    orphan bundle cited as motivation (`20260809-184015-chat`) sits between two rows BOTH written
    by `bench_llamacpp.sh`. A fix that covered only the vLLM bencher would have missed it."""

    ENGINES = {
        "llamacpp": ("scripts/bench_llamacpp.sh", "llama-server"),
        "ds4": ("scripts/bench_ds4.sh", "ds4-server"),
    }

    def host_repo(self, engine: str):
        script, server = self.ENGINES[engine]
        api.require_file(self, api.REPO_ROOT / script, "B2 owns " + script)
        api.require_file(self, api.REPO_ROOT / "scripts" / "lib" / "hostcfg.sh",
                         "host-process config identity")
        r = self.repo()
        for rel in (script, "scripts/lib/hostcfg.sh"):
            (r.root / rel).write_bytes((api.REPO_ROOT / rel).read_bytes())
        (r.root / rel).chmod(0o755)
        # ds4 hardcodes its org/model; llamacpp takes them from the stub.
        r.host_out = (r.root / "results" / "gb10-test" / "antirez" / "DeepSeek-V4-Flash"
                      if engine == "ds4" else r.out_dir)
        r.host_out.mkdir(parents=True, exist_ok=True)
        r.host_tsv = r.host_out / "results.tsv"
        r.stub = r.root / "stub.smoke-runbook.sh"
        r.stub.write_text("MODEL=Org/Model\nSERVED_NAME=m\nPROCESSOR=Org/Model\n")
        # The "served" process: its argv is what config_hash is computed from.
        fake = _write_exec(r.root / "bin" / server, FAKE_SERVER)
        r.server = subprocess.Popen(
            ["bash", str(fake), "--host", "127.0.0.1", "--port", "8000",
             "-m", "/models/model-Q5_K_M.gguf", "-np", "16", "-c", "16384", "-ngl", "99"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self._sessions.append(r.server.pid)
        self._procs.append(r.server)
        # The bencher locates its engine with `pgrep -f`; wait until it is findable rather than
        # racing it.
        pattern = server + " .*--port 8000"
        deadline = time.time() + 20
        while time.time() < deadline:
            if subprocess.run(["pgrep", "-f", pattern],
                              capture_output=True).returncode == 0:
                return r
            time.sleep(0.05)
        self.fail("the stand-in %s never became visible to pgrep — harness broken" % server)

    def host_env(self, repo, **extra):
        e = self.base_env(repo, **extra)
        e["TAG"] = "acceptance"
        e["LEVELS_SET"] = "1,16"
        return e

    def start_host(self, repo, engine, *shapes, **env) -> subprocess.Popen:
        script = self.ENGINES[engine][0]
        argv = ["bash", str(repo.root / script)]
        if engine != "ds4":
            argv.append(str(repo.stub))
        argv += list(shapes or ("chat",))
        out, err = repo.root / "out.host", repo.root / "err.host"
        self._fo, self._fe = out.open("w"), err.open("w")
        proc = subprocess.Popen(argv, cwd=str(repo.root), stdout=self._fo, stderr=self._fe,
                                env=self.host_env(repo, **env), start_new_session=True)
        proc._ahl_out, proc._ahl_err, proc._ahl_argv = out, err, argv
        self._sessions.append(proc.pid)
        return proc

    def host_rows(self, repo):
        return api.read_tsv(repo.host_tsv) if repo.host_tsv.exists() else []


class TestHostBenchersRecordAnInterruptedShape(HostBenchTestCase):
    def interrupted_host_run(self, engine, sig=signal.SIGTERM):
        repo = self.host_repo(engine)
        proc = self.start_host(repo, engine, "chat", AHL_STUB_BLOCK="16",
                               AHL_STUB_BLOCK_SECS="12", LEVEL_TIMEOUT="300")
        deadline = time.time() + 60
        while time.time() < deadline:
            if list((repo.host_out / "data").glob("*/.started_c16")):
                break
            if proc.poll() is not None:
                break
            time.sleep(0.02)
        proc.send_signal(sig)
        return repo, self.finish(proc, timeout=90)

    def test_llamacpp_records_the_partial_shape(self):
        repo, proc = self.interrupted_host_run("llamacpp")
        rows = self.host_rows(repo)
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("suspect", rows[0]["status"], self.show(proc, rows))
        self.assertIn("interrupted", rows[0]["notes"], self.show(proc, rows))
        self.assertEqual("20", rows[0]["tps_c1"], "the completed level keeps its number")
        self.assertEqual("na", rows[0]["tps_c16"], "`na` is not run; `hang` claims a wedge")

    def test_ds4_records_the_partial_shape(self):
        repo, proc = self.interrupted_host_run("ds4")
        rows = self.host_rows(repo)
        self.assertEqual(1, len(rows), self.show(proc, rows))
        self.assertEqual("suspect", rows[0]["status"], self.show(proc, rows))
        self.assertIn("interrupted", rows[0]["notes"], self.show(proc, rows))

    def test_the_partial_host_row_points_at_its_bundle(self):
        repo, proc = self.interrupted_host_run("llamacpp")
        row = self.host_rows(repo)[-1]
        bundles = [p.name for p in (repo.host_out / "data").iterdir() if p.is_dir()]
        self.assertEqual(1, len(bundles), self.show(proc, [row]))
        self.assertEqual(bundles[0], row["run_id"], self.show(proc, [row]))
        self.assertTrue(row["data"].endswith(bundles[0]), self.show(proc, [row]))

    def test_a_completed_host_run_writes_exactly_one_row(self):
        """The other half: closing the hole must not add a row to a run that finishes."""
        repo = self.host_repo("llamacpp")
        proc = self.start_host(repo, "llamacpp", "chat")
        done = self.finish(proc, timeout=90)
        rows = self.host_rows(repo)
        self.assertEqual(1, len(rows), self.show(done, rows))
        self.assertEqual("measured", rows[0]["status"], self.show(done, rows))
        self.assertEqual(0, done.returncode, self.show(done, rows))

    def test_the_two_host_benchers_share_the_mechanism_byte_for_byte(self):
        """They already shared their validity and crash blocks verbatim; the interrupt block is
        held to the same standard, so a fix to one can never silently miss the other."""
        def block(path, start, end):
            src = (api.REPO_ROOT / path).read_text()
            return src[src.index(start):src.index(end)]

        start = "# ── Interrupt safety (BYTE-IDENTICAL"
        a = block("scripts/bench_ds4.sh", start, "run_level() {")
        b = block("scripts/bench_llamacpp.sh", start, "run_level() {")
        self.assertEqual(a, b, "the shared interrupt block has drifted between the two benchers")
        va = block("scripts/bench_ds4.sh", "  # Validity: rules live in the library.", "done\nexit ")
        vb = block("scripts/bench_llamacpp.sh", "  # Validity: rules live in the library.",
                   "done\nexit ")
        self.assertEqual(va, vb, "the shared validity + crash block has drifted")


if __name__ == "__main__":              # pragma: no cover
    unittest.main()
