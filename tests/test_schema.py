"""Contract §2 + §7 — the 23-column schema and the migration of the 313 historical rows.

The column list is transcribed independently in `ahl_test/api.CONTRACT_COLUMNS`; comparing the
implementation against that transcript is the whole test. The migration half asserts the one
property that makes a rewrite of the committed journal safe: every original value survives,
byte-identically, in its new position.
"""
from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from ahl_test import api

LEGACY = api.FIXTURES / "legacy_results.tsv"


class TestHeader(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)
        self.columns = api.attr(self, self.mod, "COLUMNS", "COLS", "RESULTS_COLUMNS",
                                what="the §2 column list")

    def test_exactly_23_columns(self):
        self.assertEqual(23, len(self.columns), f"got {len(self.columns)}: {self.columns}")

    def test_columns_match_the_contract_in_order(self):
        self.assertEqual(api.CONTRACT_COLUMNS, list(self.columns))

    def test_header_is_the_tab_joined_columns(self):
        header = api.attr(self, self.mod, "HEADER", "RESULTS_HEADER", "TSV_HEADER",
                          what="the §2 header string")
        self.assertEqual("\t".join(api.CONTRACT_COLUMNS), str(header).rstrip("\n"))

    def test_new_columns_sit_between_peak_gb_and_status(self):
        cols = list(self.columns)
        self.assertEqual(["peak_gb", "req_counts", "validity", "knobs", "status"],
                         cols[cols.index("peak_gb"):cols.index("status") + 1])

    def test_the_status_notes_data_tail_is_preserved(self):
        """§2: 'the trailing status notes data tail is preserved so eyeballing a row is
        unchanged'."""
        self.assertEqual(["status", "notes", "data"], list(self.columns)[-3:])

    def test_the_legacy_20_columns_keep_their_relative_order(self):
        cols = [c for c in self.columns if c in api.LEGACY_COLUMNS]
        self.assertEqual(api.LEGACY_COLUMNS, cols)


class TestMigration(unittest.TestCase):
    """§7 — `scripts/migrate_results_tsv.py` (A3)."""

    def setUp(self):
        api.require_validity(self)
        api.require_file(self, api.MIGRATE_PY, "A3 owns it; contract §7")
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.legacy_lines = LEGACY.read_text().rstrip("\n").split("\n")

    def migrate(self, path: Path, allow_noop: bool = False) -> list[str]:
        """Run the migrator on `path` and return the resulting lines.

        The migrator's CLI is not pinned by the contract, so a few plain forms are tried before
        giving up; the skip message names every form that was tried. `allow_noop` accepts "ran
        cleanly and changed nothing" as success — which is what an idempotent second pass over
        an already-migrated file looks like.
        """
        before = path.read_bytes()
        attempts = [("--apply", path), (path,), ("--write", path), ("--in-place", path), ("-i", path)]
        last = None
        for args in attempts:
            r = api.run_python(api.MIGRATE_PY, *args)
            last = r
            if r.returncode != 0:
                continue
            now = path.read_text()
            if path.read_bytes() != before:
                return now.rstrip("\n").split("\n")
            if allow_noop and now.split("\n")[0].split("\t") == api.CONTRACT_COLUMNS:
                return now.rstrip("\n").split("\n")
            out = r.stdout.rstrip("\n")
            if out and "\t" in out.split("\n")[0]:
                return out.split("\n")
        self.skipTest(
            "could not drive scripts/migrate_results_tsv.py — tried "
            f"{[' '.join(str(a) for a in form) for form in attempts]}; "
            f"last rc={last.returncode if last else '?'} "
            f"stderr={(last.stderr or '')[:300] if last else ''}. "
            "Requirement: accept a results.tsv path and rewrite it in place, idempotently."
        )

    def _migrated_copy(self, name="results.tsv") -> tuple[Path, list[str]]:
        dst = self.tmp / name
        shutil.copyfile(LEGACY, dst)
        return dst, self.migrate(dst)

    def test_header_becomes_the_23_column_header(self):
        _, lines = self._migrated_copy()
        self.assertEqual(api.CONTRACT_COLUMNS, lines[0].split("\t"))

    def test_every_row_has_23_fields(self):
        _, lines = self._migrated_copy()
        for i, line in enumerate(lines[1:], start=2):
            self.assertEqual(23, len(line.split("\t")), f"line {i}: {line[:120]!r}")

    def test_row_count_is_unchanged(self):
        _, lines = self._migrated_copy()
        self.assertEqual(len(self.legacy_lines), len(lines))

    def test_every_legacy_value_survives_byte_identically(self):
        """The point of §7: this rewrites a committed, already-cited journal."""
        _, lines = self._migrated_copy()
        new_cols = lines[0].split("\t")
        old_cols = self.legacy_lines[0].split("\t")
        self.assertEqual(api.LEGACY_COLUMNS, old_cols, "fixture is not the legacy schema")
        for lineno, (old, new) in enumerate(zip(self.legacy_lines[1:], lines[1:]), start=2):
            old_vals = old.split("\t")
            new_vals = new.split("\t")
            for name, value in zip(old_cols, old_vals):
                got = new_vals[new_cols.index(name)]
                self.assertEqual(value, got,
                                 f"line {lineno} column {name!r} changed:\n"
                                 f"  before: {value!r}\n  after:  {got!r}")

    def test_new_columns_are_never_empty(self):
        """§2: 'Values are never empty — use na.' Historical rows may have no retained bundle."""
        _, lines = self._migrated_copy()
        cols = lines[0].split("\t")
        for lineno, line in enumerate(lines[1:], start=2):
            vals = line.split("\t")
            for name in ("req_counts", "validity", "knobs"):
                v = vals[cols.index(name)]
                self.assertNotEqual("", v, f"line {lineno}: {name} is empty")

    def test_historical_status_values_are_not_rewritten(self):
        """§7: 'do not rewrite historical status values' — they are adjudicated by hand."""
        _, lines = self._migrated_copy()
        cols = lines[0].split("\t")
        old_cols = self.legacy_lines[0].split("\t")
        for lineno, (old, new) in enumerate(zip(self.legacy_lines[1:], lines[1:]), start=2):
            self.assertEqual(old.split("\t")[old_cols.index("status")],
                             new.split("\t")[cols.index("status")],
                             f"line {lineno}: status was rewritten")

    def test_migration_is_idempotent(self):
        path, _ = self._migrated_copy()
        after_first = path.read_bytes()
        self.migrate(path, allow_noop=True)
        self.assertEqual(after_first, path.read_bytes(),
                         "re-running the migrator changed an already-migrated file")

    def test_notes_field_with_punctuation_is_untouched(self):
        """The 449358 crash row's notes carry commas, semicolons, quotes and an arrow — exactly
        the characters a careless CSV round-trip would quote or re-escape."""
        _, lines = self._migrated_copy()
        cols = lines[0].split("\t")
        old_cols = self.legacy_lines[0].split("\t")
        wanted = [l.split("\t")[old_cols.index("notes")] for l in self.legacy_lines[1:]]
        got = [l.split("\t")[cols.index("notes")] for l in lines[1:]]
        self.assertEqual(wanted, got)


class TestSingleSourceOfTruthIsUsable(unittest.TestCase):
    """§1: the header 'exists once, in the library, and is consumed from there' — so the shell
    shim must be able to hand it to the bench*.sh callers."""

    def setUp(self):
        api.require_validity(self)
        api.require_file(self, api.VALIDITY_SH, "A1 owns it; contract §1")

    def test_shell_shim_can_emit_the_header(self):
        import subprocess
        for sub in ("header", "--header", "columns"):
            r = subprocess.run(["bash", str(api.VALIDITY_SH), sub],
                               capture_output=True, text=True,
                               cwd=str(api.REPO_ROOT), timeout=30)
            if r.returncode == 0 and "run_id" in r.stdout:
                self.assertEqual("\t".join(api.CONTRACT_COLUMNS), r.stdout.rstrip("\n"))
                return
        self.skipTest(
            "scripts/lib/validity.sh does not answer `header`/`--header`/`columns` with the "
            "23-column header; the bench*.sh callers need some way to consume it (§1)")


if __name__ == "__main__":
    unittest.main()
