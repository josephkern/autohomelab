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
only then signals. No timing guesses.
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


class InterruptTestCase(unittest.TestCase):
    def setUp(self):
        api.require_file(self, api.REPO_ROOT / "scripts" / "bench.sh", "B2 owns scripts/bench.sh")
        api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0

    # ── harness ───────────────────────────────────────────────────────────────────────────
    def repo(self, levels=None) -> ScratchRepo:
        self.n += 1
        r = ScratchRepo(self.tmp / f"r{self.n}", levels=levels)
        # `import guidellm_stub` needs the stock stub to be importable, so keep it and add ours.
        (r.root / "bin" / "blocking_stub.py").write_text(BLOCKING_STUB)
        uv = r.root / "bin" / "uv"
        uv.write_text(uv.read_text().replace("guidellm_stub.py", "blocking_stub.py"))
        return r

    def interrupt(self, repo, *shapes, block_level: int, sig=signal.SIGINT, to_group: bool = False,
                  block_match: str = "", timeout: float = 60.0, **env) -> subprocess.CompletedProcess:
        """Start the real bench.sh, wait until it is provably inside level `block_level`,
        then deliver `sig` to it. Returns once the process is reaped.

        `to_group=True` signals the whole process group — what a terminal Ctrl-C does. The
        default signals bench.sh alone — what a session limit, a supervisor or `kill <pid>`
        does, and the case where bash would defer the trap until the level ended.
        """
        e = repo.env(**env)
        e["AHL_STUB_BLOCK"] = str(block_level)
        e["AHL_STUB_BLOCK_MATCH"] = block_match   # e.g. "-coder": block only in that shape
        e["AHL_STUB_BLOCK_SECS"] = "30"     # bound any stray if the harness itself is killed
        e["LEVEL_TIMEOUT"] = "300"          # the hard timeout must not fire before we signal
        out = repo.root / "out.sig"
        err = repo.root / "err.sig"
        argv = ["bash", str(repo.root / "scripts" / "bench.sh"), str(repo.runbook),
                *(shapes or ("chat",))]
        with out.open("w") as fo, err.open("w") as fe:
            # Own process group: a test must never signal the whole test runner.
            proc = subprocess.Popen(argv, cwd=str(repo.root), stdout=fo, stderr=fe, env=e,
                                    start_new_session=True)
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
        self.assertLess(time.time() - t0, 25,
                        "the handler must not wait out the blocking level (30 s)")

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


if __name__ == "__main__":              # pragma: no cover
    unittest.main()
