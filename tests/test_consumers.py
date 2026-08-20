"""Contract §1 and §5 downstream — the consumers, EXECUTED.

`test_wiring.py` asserted these with `assertIn("void", src)`, which a comment satisfies. Here the
real `aggregate.py` and the real `validity.sh` are run against a fixture journal and the
assertions are on their output.

Two promises are pinned:

* §1 single source of truth — the 23-column header exists ONCE, in `scripts/lib/validity.py`, and
  every consumer *reads* it. Proven by moving the library's definition and checking the consumer
  moved with it; a hard-coded copy in `validity.sh` or `bench.sh` fails immediately.
* §5 default view — `aggregate.py` hides `void`, `suspect` and `crash` rows, and it filters on
  `validity`, never on `status` alone ("a crash row carrying `over_roofline` would sail through a
  status-only filter; that is exactly the class of hole this layer exists to close").

Note on how the aggregate assertions identify a row: the printed table does NOT contain `run_id`,
so an assertion like `assertNotIn(run_id, stdout)` would pass no matter what the filter did. Rows
are identified by their `tps_c16` cell, which IS printed, and the visible row count is asserted
too. Writing that check the obvious way is exactly the vacuous-assertion trap this whole exercise
is about.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api
from ahl_test.scratch import ScratchRepo

# Each fixture row is identifiable in the printed table by its tps_c16 cell.
OK_ROW = "400"
VOID_ROW = "999"
SUSPECT_ROW = "401"
LYING_ROW = "449358.18"          # status=measured, validity=over_roofline@c16
CRASH_ROW = "hang"
NA_ROW = "402"                   # status=measured, validity=na


class ConsumerTestCase(unittest.TestCase):
    def setUp(self):
        api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0

    def repo(self) -> ScratchRepo:
        self.n += 1
        return ScratchRepo(self.tmp / f"r{self.n}")


class TestHeaderHasOneDefinition(ConsumerTestCase):
    """§1: 'The header string previously existed in four hard-coded copies (`bench.sh`,
    `bench_ds4.sh`, `bench_llamacpp.sh`, `aggregate.py`) — all four now consume it from the
    library.'"""

    def sh_header(self, repo) -> str:
        proc = api.run_bash(repo.root / "scripts" / "lib" / "validity.sh", "header",
                            cwd=repo.root, env=repo.env())
        self.assertEqual(0, proc.returncode,
                         f"validity.sh header failed\nstderr:\n{proc.stderr}")
        return proc.stdout.strip()

    def test_the_shim_prints_the_contract_header(self):
        repo = self.repo()
        self.assertEqual("\t".join(api.CONTRACT_COLUMNS), self.sh_header(repo),
                         "§2 fixes the 23 columns and their order")

    def test_the_shim_reads_the_header_from_the_library(self):
        """Rename the library's last column; the shim must report the new name. A shim carrying
        its own copy of the string reports the old one and this fails."""
        repo = self.repo()
        repo.patch_library_schema()
        header = self.sh_header(repo)
        self.assertIn("data_SENTINEL", header,
                      "validity.sh is not reading the schema from validity.py (§1)\n"
                      f"got: {header}")

    def test_bench_writes_the_header_it_got_from_the_library(self):
        """The same test one layer out: bench.sh's `results.tsv` header must move too."""
        repo = self.repo()
        repo.patch_library_schema()
        proc = repo.bench("chat")
        self.assertTrue(repo.tsv.exists(),
                        f"bench.sh wrote no results.tsv\nstderr:\n{proc.stderr}")
        header = repo.tsv.read_text().splitlines()[0]
        self.assertIn("data_SENTINEL", header,
                      "bench.sh must consume the header from the library, not hard-code it\n"
                      f"got: {header}")

    def test_the_shim_carries_no_thresholds_of_its_own(self):
        """§1: 'a thin bash shim; it re-implements nothing.' A shim with its own arithmetic is
        a second source of truth that will drift."""
        if not api.VALIDITY_SH.exists():
            self.skipTest("scripts/lib/validity.sh not implemented yet (F3 owns it)")
        code = "\n".join(l for l in api.VALIDITY_SH.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        for pattern, rule in ((r"-lt\s+5\b|<\s*5\b", "MIN_DATA"),
                              (r"-lt\s+20\b|<\s*20\b", "MIN_SUCCESSFUL"),
                              (r"0\.30|0\.50", "the A2/A4 tolerances")):
            self.assertNotRegex(code, pattern,
                                f"validity.sh appears to re-implement {rule} (§1)")


class TestAggregateDefaultView(ConsumerTestCase):
    """§5: '`aggregate.py` hides them by default' and '**consumers filter on `validity`, never on
    `status` alone**'."""

    def journal(self):
        """One citable row plus one of every kind that must be held back."""
        repo = self.repo()
        repo.add_row(run_id="20260819-000001-chat", status="measured", validity="ok",
                     tps_c16=OK_ROW)
        repo.add_row(run_id="20260819-000002-void", status="void",
                     validity="no_data@c16", tps_c16=VOID_ROW)
        repo.add_row(run_id="20260819-000003-susp", status="suspect",
                     validity="low_sample@c16", tps_c16=SUSPECT_ROW)
        # status says `measured`, validity says otherwise — the status-only filter's blind spot.
        repo.add_row(run_id="20260819-000004-lying", status="measured",
                     validity="over_roofline@c16", tps_c16=LYING_ROW)
        # a crash row whose validity reads clean: §5 v1.1 makes crash non-valid regardless.
        repo.add_row(run_id="20260819-000005-crash", status="crash", validity="ok",
                     tps_c16=CRASH_ROW)
        # `na` is never `ok` (§3 / A5)
        repo.add_row(run_id="20260819-000006-na", status="measured", validity="na",
                     req_counts="na", tps_c16=NA_ROW)
        return repo

    @staticmethod
    def body(proc) -> list:
        """The data rows of the printed table (the header line dropped)."""
        lines = [l for l in proc.stdout.splitlines() if l.strip()]
        return lines[1:] if lines else []

    def cells(self, proc) -> set:
        return {c for line in self.body(proc) for c in line.split()}

    def test_only_the_citable_row_is_shown(self):
        repo = self.journal()
        proc = repo.aggregate()
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual(1, len(self.body(proc)),
                         "1 of 6 rows is citable\n" + proc.stdout)
        self.assertIn(OK_ROW, self.cells(proc), proc.stdout)

    def test_void_and_suspect_and_crash_are_hidden(self):
        repo = self.journal()
        proc = repo.aggregate()
        shown = self.cells(proc)
        for label, cell in (("void", VOID_ROW), ("suspect", SUSPECT_ROW),
                            ("crash", CRASH_ROW)):
            with self.subTest(row=label):
                self.assertNotIn(cell, shown,
                                 f"§5: the {label} row must not appear\n{proc.stdout}")

    def test_a_measured_row_with_a_fatal_verdict_is_hidden(self):
        """The whole point of filtering on `validity`: this row's `status` says `measured`."""
        repo = self.journal()
        proc = repo.aggregate()
        self.assertNotIn(LYING_ROW, self.cells(proc),
                         "a fatal verdict hides the row whatever its status says\n"
                         + proc.stdout)

    def test_an_unevaluable_row_is_hidden(self):
        repo = self.journal()
        proc = repo.aggregate()
        self.assertNotIn(NA_ROW, self.cells(proc), "§3: `na` is never `ok`\n" + proc.stdout)

    def test_what_was_held_back_is_always_reported(self):
        """Hiding silently would be its own defect — the count goes to stderr every run."""
        repo = self.journal()
        proc = repo.aggregate()
        self.assertRegex(proc.stderr, r"held back",
                         f"the default view must say what it dropped\nstderr:\n{proc.stderr}")
        self.assertRegex(proc.stderr, r"\b5\b",
                         f"5 of 6 rows were held back\nstderr:\n{proc.stderr}")

    def test_the_escape_hatch_shows_them_again(self):
        repo = self.journal()
        proc = repo.aggregate("--include-void", "--include-suspect", "--include-crash")
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual(6, len(self.body(proc)), proc.stdout)
        shown = self.cells(proc)
        for label, cell in (("void", VOID_ROW), ("suspect", SUSPECT_ROW),
                            ("crash", CRASH_ROW), ("lying", LYING_ROW), ("na", NA_ROW)):
            with self.subTest(row=label):
                self.assertIn(cell, shown, f"the {label} row must return with the escape hatch")

    def test_the_written_file_matches_the_view(self):
        """'results/aggregate.tsv is written to match the view exactly — it is never a wider set
        than what was printed, so nothing silently leaks into a downstream consumer.'

        The file DOES carry `run_id`, so rows are identified by it here.
        """
        repo = self.journal()
        repo.aggregate()
        out = repo.root / "results" / "aggregate.tsv"
        self.assertTrue(out.exists(), "aggregate.tsv was not written")
        body = out.read_text()
        self.assertIn("20260819-000001-chat", body)
        for rid in ("20260819-000002-void", "20260819-000003-susp", "20260819-000004-lying",
                    "20260819-000005-crash", "20260819-000006-na"):
            with self.subTest(row=rid):
                self.assertNotIn(rid, body, f"{rid} leaked into aggregate.tsv")

    def test_a_journal_of_only_bad_rows_shows_nothing_rather_than_lying(self):
        repo = self.repo()
        repo.add_row(run_id="20260819-000009-void", status="void", validity="no_data@c16",
                     tps_c16=VOID_ROW)
        proc = repo.aggregate()
        self.assertNotEqual(0, proc.returncode,
                            "no citable rows is not a successful comparison table")
        self.assertNotIn(VOID_ROW, self.cells(proc), proc.stdout)


if __name__ == "__main__":
    unittest.main()
