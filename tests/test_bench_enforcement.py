"""Contract §5 + v1.2 A6 — the enforcement path, EXECUTED.

Every test here runs the real `scripts/bench.sh` inside a `ScratchRepo` (see
`tests/ahl_test/scratch.py`) whose children are logging stubs, and asserts on what the run left
behind: the `results.tsv` row, the process exit code, and the stub call log. Nothing is grepped.

This module exists because eight enforcement mutations survived the previous suite. Each could be
applied to `bench.sh` today with 121/121 still green:

  * delete `status="$STATUS_FLOOR"`      — an invalid row keeps `status=measured`
  * turn `return 4` into `return 0`      — callers never learn the row is not citable
  * make `check_validity` hard-code `ok` — the library is never consulted
  * delete the `check_validity` call     — no verdict is computed at all
  * never pass `--node-profile`          — §4 is dead code (this one was REAL, A6)
  * fail open when the library errors     — a `uv` hiccup produced a fully citable row (A6)

The rule of thumb the whole module follows: an assertion that could be satisfied by a comment is
not an assertion.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api
from ahl_test.scratch import ScratchRepo

# tps_c16 = 449,358.18 on a 273 GB/s node — contract §0 defect (b). The §4 ceiling at c16 is
# 3.0 * 16 * 273 = 13,104 tok/s, so this is over by 34x.
IMPOSSIBLE = 449358.18


class BenchTestCase(unittest.TestCase):
    def setUp(self):
        api.require_file(self, api.REPO_ROOT / "scripts" / "bench.sh", "F3 owns scripts/bench.sh")
        api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0

    def repo(self, levels=None, mem_bw=273.0) -> ScratchRepo:
        self.n += 1
        return ScratchRepo(self.tmp / f"r{self.n}", levels=levels, mem_bw=mem_bw)

    def run_bench(self, levels=None, mem_bw=273.0, **env):
        repo = self.repo(levels, mem_bw)
        proc = repo.bench("chat", **env)
        rows = repo.rows()
        self.assertTrue(rows, "contract §5: 'A failing run is still written' — no row appeared\n"
                              f"stderr:\n{proc.stderr}")
        return repo, proc, rows[-1]

    def show(self, proc, row):
        return (f"rc={proc.returncode} status={row['status']!r} validity={row['validity']!r} "
                f"req_counts={row['req_counts']!r}\nstderr:\n{proc.stderr[-2000:]}")


class TestHealthyRun(BenchTestCase):
    """The false-positive guard for the wiring: a good sweep must come out clean and exit 0."""

    def test_a_healthy_sweep_is_measured_ok_and_exits_zero(self):
        repo, proc, row = self.run_bench()
        self.assertEqual(0, proc.returncode, self.show(proc, row))
        self.assertEqual("measured", row["status"], self.show(proc, row))
        self.assertEqual("ok", row["validity"], self.show(proc, row))

    def test_the_row_carries_counts_read_from_the_bundle(self):
        """`req_counts` cannot be produced by a `check_validity` that hard-codes `ok` — the
        numbers only exist inside the level JSON the stub wrote."""
        repo, proc, row = self.run_bench()
        self.assertEqual("c1:41/0/0;c16:118/4/0", row["req_counts"], self.show(proc, row))

    def test_the_caller_status_survives_a_clean_run(self):
        """§5: an `ok` floor leaves the caller's `STATUS=` alone. `discard` stands in for "any
        caller status" here — §6 v1.3 retired `keep`, so it is the only non-default word left,
        and the runners refuse to pass even that one (it is an adjudication, made after the
        fact, not a bench-time verdict)."""
        repo, proc, row = self.run_bench(STATUS="discard")
        self.assertEqual("discard", row["status"], self.show(proc, row))
        self.assertEqual(0, proc.returncode, self.show(proc, row))

    def test_knobs_records_the_resolved_values_with_the_list_separator(self):
        """§2 value encoding (v1.1): 'No value may contain the pair separator. List values use
        `|` (`levels=1|16`), so a naive `split(",")` is always correct. v1.0's `levels=1,16`
        example was not round-trippable and is withdrawn.'"""
        repo, proc, row = self.run_bench(MAX_SECONDS="7")
        knobs = row["knobs"]
        self.assertIn("levels=1|16", knobs, f"got {knobs!r}")
        self.assertIn("max_s=7", knobs, f"the RESOLVED value, not the default; got {knobs!r}")
        parsed = dict(p.split("=", 1) for p in knobs.split(",") if "=" in p)
        self.assertEqual("1|16", parsed.get("levels"),
                         f"a naive split(',') must recover every pair; got {knobs!r}")


class TestFatalVerdictEnforcement(BenchTestCase):
    """§5: 'Fatal verdict -> `status=void` ... `bench.sh` exits 4 on any non-`ok` verdict.'"""

    def test_an_impossible_throughput_voids_the_row_and_exits_4(self):
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": IMPOSSIBLE}})
        self.assertIn("over_roofline", row["validity"], self.show(proc, row))
        self.assertEqual("void", row["status"], self.show(proc, row))
        self.assertEqual(4, proc.returncode, self.show(proc, row))

    def test_a_two_request_level_voids_the_row_and_exits_4(self):
        """No roofline involved — the sample-count rule alone must drive status and exit."""
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 2, "incomplete": 31, "tps": 256.19}},
            mem_bw=None)
        self.assertIn("no_data", row["validity"], self.show(proc, row))
        self.assertEqual("void", row["status"], self.show(proc, row))
        self.assertEqual(4, proc.returncode, self.show(proc, row))

    def test_the_numbers_are_still_written_to_the_journal(self):
        """§5: 'A failing run is still written; the evidence must survive in the committed
        journal.' Voiding must not become dropping."""
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": IMPOSSIBLE}})
        self.assertEqual("449358.18", row["tps_c16"], self.show(proc, row))
        self.assertNotEqual("na", row["data"], "the bundle path must be recorded")

    def test_stderr_says_the_row_is_not_citable(self):
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": IMPOSSIBLE}})
        self.assertIn("NOT citable", proc.stderr, self.show(proc, row))


class TestSuspectVerdictEnforcement(BenchTestCase):
    """§5 v1.1: 'exits 4 on any non-`ok` verdict, INCLUDING `suspect` alone.'"""

    def test_a_suspect_only_row_is_downgraded_and_still_exits_4(self):
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 10, "tps": 200.0}}, mem_bw=None)
        self.assertIn("low_sample", row["validity"], self.show(proc, row))
        self.assertEqual("suspect", row["status"], self.show(proc, row))
        self.assertEqual(4, proc.returncode,
                         "suspect alone is still not citable (§5 v1.1)\n" + self.show(proc, row))

    def test_a_suspect_verdict_downgrades_even_an_explicit_caller_status(self):
        """§5 downgrades; it does not merely fill in an unset status."""
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 10, "tps": 200.0}},
            mem_bw=None, STATUS="discard")
        self.assertEqual("suspect", row["status"], self.show(proc, row))


class TestCrashOutranks(BenchTestCase):
    """§5: 'crash outranks validity (3 wins), and a crash row keeps status=crash while still
    recording its verdict in the validity column.'"""

    def test_a_wedged_level_exits_3_not_4(self):
        repo, proc, row = self.run_bench({1: {"ok": 41, "tps": 20.0}, 16: None})
        self.assertEqual(3, proc.returncode, self.show(proc, row))
        self.assertEqual("crash", row["status"], self.show(proc, row))

    def test_the_wedged_level_is_marked_hang_and_named_in_the_verdict(self):
        repo, proc, row = self.run_bench({1: {"ok": 41, "tps": 20.0}, 16: None})
        self.assertEqual("hang", row["tps_c16"],
                         "§2: `hang` is the sentinel for the level that wedged\n"
                         + self.show(proc, row))
        self.assertIn("no_data@c16", row["validity"],
                      "the verdict is recorded even though the status is not downgraded\n"
                      + self.show(proc, row))

    def test_the_completed_lower_level_is_preserved(self):
        """Per-level isolation exists so a wedge does not destroy the levels that finished."""
        repo, proc, row = self.run_bench({1: {"ok": 41, "tps": 20.0}, 16: None})
        self.assertEqual("20", row["tps_c1"], self.show(proc, row))


class TestA6NodeProfileIsSupplied(BenchTestCase):
    """v1.2 A6: '`bench.sh` never passed `--node-profile`, so §4 was DEAD CODE on the vLLM path
    — the two host-process benchers passed it, the primary bencher did not.'

    Asserted two ways, because either alone can be faked: behaviourally (the same run grades
    differently with and without a bandwidth figure, so the profile is genuinely being read) and
    on the call log (the flag really appears in the library invocation).
    """

    def test_the_flag_reaches_the_library(self):
        repo = self.repo({1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": IMPOSSIBLE}})
        proc = repo.bench("chat", AHL_PYTHON=str(repo.root / "bin" / "logging_python"))
        calls = repo.calls()
        self.assertIn("--node-profile", calls,
                      "bench.sh must hand §4 its input\ncall log:\n" + calls)
        self.assertRegex(calls, r"--node-profile\s+\S*node_profile\.json",
                         "…and it must be a real node_profile.json\ncall log:\n" + calls)

    def test_the_roofline_actually_fires_on_the_vllm_path(self):
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": IMPOSSIBLE}}, mem_bw=273.0)
        self.assertIn("over_roofline", row["validity"], self.show(proc, row))

    def test_and_is_skipped_when_the_node_has_no_bandwidth_figure(self):
        """§4: 'Absent or `null` -> the check is skipped, never guessed.' Identical numbers,
        identical scripts — only the node profile differs. If these two agree, the verdict is
        not coming from the profile at all."""
        repo, proc, row = self.run_bench(
            {1: {"ok": 41, "tps": 20.0}, 16: {"ok": 118, "tps": IMPOSSIBLE}}, mem_bw=None)
        self.assertNotIn("over_roofline", row["validity"], self.show(proc, row))
        self.assertEqual(0, proc.returncode, self.show(proc, row))


class TestA6FailsClosed(BenchTestCase):
    """v1.2 A6: 'when the library call failed, `bench.sh` defaulted `STATUS_FLOOR=ok` and exited
    0: a `uv` hiccup produced a fully citable row. Treat any failure to evaluate as NOT citable
    (floor `suspect`, exit 4).'"""

    def flaky(self):
        repo = self.repo()
        proc = repo.bench("chat", AHL_PYTHON=str(repo.root / "bin" / "flaky_python"))
        rows = repo.rows()
        self.assertTrue(rows, f"the row must still be written\nstderr:\n{proc.stderr}")
        return repo, proc, rows[-1]

    def test_a_library_failure_does_not_produce_a_citable_row(self):
        repo, proc, row = self.flaky()
        self.assertNotEqual("measured", row["status"],
                            "an unevaluated row is not a measured row\n" + self.show(proc, row))
        self.assertIn(row["status"], ("suspect", "void"), self.show(proc, row))

    def test_a_library_failure_exits_4(self):
        repo, proc, row = self.flaky()
        self.assertEqual(4, proc.returncode,
                         "fail CLOSED: the caller must learn the row is not citable\n"
                         + self.show(proc, row))

    def test_a_library_failure_is_recorded_as_na_not_ok(self):
        """§3: '`na` — rules could not be evaluated — never `ok`.'"""
        repo, proc, row = self.flaky()
        self.assertNotEqual("ok", row["validity"], self.show(proc, row))


class TestExitPrecedenceAcrossShapes(BenchTestCase):
    """§5 exit-code precedence: 3 (crash) > 4 (validity) > 0, latched across shapes."""

    def test_an_invalid_first_shape_is_reported_after_a_clean_second(self):
        repo = self.repo({1: {"ok": 41, "tps": 20.0}, 16: {"ok": 10, "tps": 200.0}},
                         mem_bw=None)
        proc = repo.bench("chat", "coder")
        rows = repo.rows()
        self.assertEqual(2, len(rows), f"one row per shape\nstderr:\n{proc.stderr}")
        self.assertEqual(4, proc.returncode,
                         "rc latches and is never lowered\nstderr:\n" + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
