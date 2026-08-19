"""Contract §5/§6 — status precedence.

    any fatal verdict   -> void
    any suspect verdict -> suspect
    otherwise           -> unchanged (measured, or the caller's STATUS)
    an already-`crash` row keeps status=crash and records its verdict in `validity`

The ordering matters because `void` and `crash` mean different things to a reader: `crash` says
the box broke, `void` says the number is not data. Collapsing them loses the distinction the
contract explicitly bought with a separate exit code.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api

GB10 = api.FIXTURES / "node_profile_gb10.json"

CLEAN = {1: api.level_json(41, 0, 0, 20.0, rate=1),
         16: api.level_json(118, 0, 4, 200.0, rate=16)}
SUSPECT = {1: api.level_json(41, 0, 0, 20.0, rate=1),
           16: api.level_json(19, 0, 0, 200.0, rate=16)}          # low_sample
FATAL = {1: api.level_json(41, 0, 0, 20.0, rate=1),
         16: api.level_json(2, 0, 30, 200.0, rate=16)}            # no_data
FATAL_AND_SUSPECT = {1: api.level_json(19, 0, 0, 20.0, rate=1),   # low_sample
                     16: api.level_json(2, 0, 30, 200.0, rate=16)}  # no_data


class StatusTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0

    def verdict(self, levels, status="measured"):
        self.n += 1
        b = api.write_bundle(self.tmp / f"b{self.n}", levels)
        return api.assess(self, self.mod, b, [1, 16], node_profile=GB10, status=status)


class TestDowngrade(StatusTestCase):
    def test_clean_measured_stays_measured(self):
        self.assertEqual("measured", self.verdict(CLEAN).status)

    def test_clean_run_preserves_the_callers_status(self):
        """bench.sh callers pass STATUS=keep/discard; a passing row must not be rewritten."""
        self.assertEqual("keep", self.verdict(CLEAN, status="keep").status)

    def test_suspect_verdict_downgrades_to_suspect(self):
        v = self.verdict(SUSPECT)
        self.assertEqual("suspect", v.status, f"got {v}")

    def test_fatal_verdict_downgrades_to_void(self):
        v = self.verdict(FATAL)
        self.assertEqual("void", v.status, f"got {v}")

    def test_void_outranks_suspect(self):
        v = self.verdict(FATAL_AND_SUSPECT)
        self.assertEqual("void", v.status,
                         f"a row with both must be void, not suspect; got {v}")
        self.assertIn("no_data", v.tokens, f"got {v}")

    def test_a_suspect_verdict_downgrades_even_a_keep(self):
        """§5 downgrades, it does not merely 'set if unset'."""
        v = self.verdict(SUSPECT, status="keep")
        self.assertEqual("suspect", v.status, f"got {v}")

    def test_a_fatal_verdict_downgrades_even_a_keep(self):
        v = self.verdict(FATAL, status="keep")
        self.assertEqual("void", v.status, f"got {v}")


class TestCrashWins(StatusTestCase):
    """§5: 'A crash still wins: an already-crash row keeps status=crash and its verdict is
    recorded in validity.'"""

    def test_crash_outranks_a_fatal_downgrade(self):
        v = self.verdict(FATAL, status="crash")
        self.assertEqual("crash", v.status, f"crash must not be rewritten to void; got {v}")

    def test_crash_outranks_a_suspect_downgrade(self):
        v = self.verdict(SUSPECT, status="crash")
        self.assertEqual("crash", v.status, f"got {v}")

    def test_crash_row_still_records_its_verdict(self):
        v = self.verdict(FATAL, status="crash")
        self.assertIn("no_data", v.tokens,
                      f"the verdict is recorded even when the status is not downgraded; got {v}")

    def test_crash_row_with_clean_levels_keeps_crash_and_ok(self):
        """The completed levels before a wedge are real; the row is `crash` with `validity=ok`."""
        v = self.verdict(CLEAN, status="crash")
        self.assertEqual("crash", v.status, f"got {v}")
        self.assertEqual("ok", str(v.validity), f"got {v}")


class TestStatusVocabulary(unittest.TestCase):
    """§6: measured · keep · discard · crash · suspect · void."""

    def setUp(self):
        self.mod = api.require_validity(self)

    def test_vocabulary_is_exposed_and_complete(self):
        vocab = api.attr(self, self.mod, "STATUSES", "STATUS_VOCABULARY", "VALID_STATUSES",
                         what="the §6 status vocabulary")
        self.assertEqual({"measured", "keep", "discard", "crash", "suspect", "void"},
                         set(vocab))


class TestExitCode(unittest.TestCase):
    """§5: bench.sh exits 4 on a validity failure, distinct from 3 = crash/hang.

    bench.sh cannot be executed here (it needs docker, a live endpoint and the GPU), so the
    constant is asserted on the library and the wiring is asserted statically in test_wiring.py.
    """

    def setUp(self):
        self.mod = api.require_validity(self)

    def test_validity_failure_exit_code_is_4(self):
        code = api.attr(self, self.mod, "EXIT_INVALID", "EXIT_VALIDITY", "EXIT_CODE_INVALID",
                        "VALIDITY_EXIT_CODE", what="the §5 exit code")
        self.assertEqual(4, int(code))


if __name__ == "__main__":
    unittest.main()
