"""Contract §5/§6 — status precedence.

    any fatal verdict   -> void
    any suspect verdict -> suspect
    otherwise           -> unchanged (measured, or the caller's STATUS)
    an already-`crash` row keeps status=crash and records its verdict in `validity`

The ordering matters because `void` and `crash` mean different things to a reader: `crash` says
the box broke, `void` says the number is not data. Collapsing them loses the distinction the
contract explicitly bought with a separate exit code.

§6 v1.3 (2026-08-20): the vocabulary is FIVE words -- `keep` is RETIRED (never written, 0 of 317
rows; wrong grain and wrong time) and `discard` is redefined as an ORCHESTRATOR ADJUDICATION under
§7, applied to the journal after the fact and carrying `adjudicated@YYYYMMDD who: reason` in
`notes`. The tests below therefore exercise the pass-through and the downgrade with `discard`,
which is the only non-default status a human can set, and assert that the retired word raises
rather than being laundered through.
"""
from __future__ import annotations

import subprocess
import sys
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
        """§5: an `ok` floor leaves the caller's status untouched.

        The status exercised is `discard`, because after v1.3 it is the only status a human sets
        by hand: re-assessing an already-adjudicated row must report the same verdict, not quietly
        promote it back to `measured`.
        """
        self.assertEqual("discard", self.verdict(CLEAN, status="discard").status)

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

    def test_a_suspect_verdict_downgrades_even_a_hand_set_discard(self):
        """§5 downgrades, it does not merely 'set if unset'."""
        v = self.verdict(SUSPECT, status="discard")
        self.assertEqual("suspect", v.status, f"got {v}")

    def test_a_fatal_verdict_downgrades_even_a_hand_set_discard(self):
        """The WRITE path always downgrades. §7's hand adjudication is the deliberate exception:
        an orchestrator may leave a published `discard` standing over a void floor -- five rows in
        the corpus do -- and the `adjudicated@…` stamp in `notes` is what records that choice."""
        v = self.verdict(FATAL, status="discard")
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
    """§6 v1.3: measured · discard · crash · suspect · void. FIVE words."""

    def setUp(self):
        self.mod = api.require_validity(self)

    def test_vocabulary_is_exposed_and_complete(self):
        vocab = api.attr(self, self.mod, "STATUSES", "STATUS_VOCABULARY", "VALID_STATUSES",
                         what="the §6 status vocabulary")
        self.assertEqual({"measured", "discard", "crash", "suspect", "void"}, set(vocab))

    def test_keep_is_retired_and_says_so(self):
        """Removing a word silently is how a consumer keeps writing it. The library carries the
        retirement, with the evidence: 0 of 317 rows, per-config verdict on a per-row column."""
        vocab = api.attr(self, self.mod, "STATUSES", "STATUS_VOCABULARY", "VALID_STATUSES",
                         what="the §6 status vocabulary")
        self.assertNotIn("keep", set(vocab))
        retired = api.attr(self, self.mod, "STATUS_RETIRED", what="the retired-status notice")
        self.assertIn("keep", retired)
        self.assertIn("retired", retired["keep"].lower())

    def test_the_library_refuses_the_retired_word(self):
        """`keep` must RAISE, not pass through §5's `ok`-floor branch into a journal row."""
        with self.assertRaises(ValueError) as cm:
            self.mod.apply_status("keep", "ok")
        self.assertIn("keep", str(cm.exception))

    def test_an_unknown_word_is_refused_too(self):
        with self.assertRaises(ValueError):
            self.mod.apply_status("kept", "ok")

    def test_measured_and_crash_still_pass_through(self):
        """The false-positive guard for the two assertions above."""
        self.assertEqual("measured", self.mod.apply_status("measured", "ok"))
        self.assertEqual("crash", self.mod.apply_status("crash", "void"))


class TestDiscardCarriesItsAdjudication(unittest.TestCase):
    """§6/§7 v1.3: `discard` is the one status the invariants cannot justify, so the human who
    set it must sign it -- `adjudicated@YYYYMMDD who: reason` in `notes`.

    Why the status survives at all: run `20260809-183024-chat` (the FF711 `NP=32` bench) is
    `valid` at c16, the tuning objective, and carries only `survivorship@c32`. It is rejected
    because `NP=32 x CTX_PER_SLOT=12288` swapped unified memory -- which no GuideLLM json records.
    Nothing in `validity` can ever reach that class of defect.
    """

    def setUp(self):
        self.mod = api.require_validity(self)

    def test_a_discard_without_a_stamp_is_refused(self):
        with self.assertRaises(ValueError) as cm:
            self.mod.check_status("discard", "cfg=np32 CONTAMINATED: swapped")
        self.assertIn("adjudicated@", str(cm.exception))

    def test_a_stamped_discard_is_accepted(self):
        notes = ("cfg=np32 CONTAMINATED: swapped; "
                 "adjudicated@20260809 jk: NP=32 over-committed unified memory into swap")
        self.assertEqual("discard", self.mod.check_status("discard", notes))

    def test_the_stamp_parses_into_date_who_and_reason(self):
        got = self.mod.parse_adjudication(
            "x; adjudicated@20260809 jk: NP=32 swapped unified memory")
        self.assertEqual(("20260809", "jk"), got[:2])
        self.assertIn("swapped", got[2])

    def test_a_reason_that_says_nothing_is_not_a_signature(self):
        """Same rule as promote.sh's AHL_PROMOTE_OVERRIDE: an adjudication is an argument, not a
        flag, so a bare word does not qualify."""
        self.assertFalse(self.mod.is_adjudicated("adjudicated@20260809 jk: x"))

    def test_an_implausible_date_is_not_a_signature(self):
        self.assertFalse(self.mod.is_adjudicated(
            "adjudicated@20261399 jk: month 13 does not exist"))

    def test_the_other_statuses_need_no_signature(self):
        """`void`/`suspect` are computed by the invariants and `crash` by the watchdog -- none of
        them is a human judgement, so demanding a signature would be noise."""
        for st in ("measured", "void", "suspect", "crash"):
            with self.subTest(status=st):
                self.assertEqual(st, self.mod.check_status(st, "na"))


class TestStatusCLI(unittest.TestCase):
    """The enforcement surface an orchestrator actually runs. The acceptance suite is hermetic
    and never reads the live results tree, so the journal-wide check is a CLI over a path the
    caller supplies -- exercised here on a synthetic journal."""

    def setUp(self):
        api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(api.VALIDITY_PY), "status", *args],
                              capture_output=True, text=True, timeout=60)

    def journal(self, status: str, notes: str) -> Path:
        cols = api.load_validity().RESULTS_COLS
        row = {c: "na" for c in cols}
        row.update(run_id="20260820-000001-chat", status=status, notes=notes)
        p = self.tmp / "results.tsv"
        p.write_text("\t".join(cols) + "\n" + "\t".join(row[c] for c in cols) + "\n")
        return p

    def test_the_retired_word_exits_on_the_usage_rung(self):
        proc = self.cli("--status", "keep")
        self.assertEqual(2, proc.returncode, proc.stderr)
        self.assertIn("retired", proc.stderr)

    def test_a_legal_word_exits_zero(self):
        self.assertEqual(0, self.cli("--status", "measured").returncode)

    def test_an_unstamped_discard_row_fails_the_journal_scan(self):
        p = self.journal("discard", "CONTAMINATED: swapped")
        proc = self.cli("--tsv", str(p))
        self.assertEqual(4, proc.returncode, proc.stderr)
        self.assertIn("20260820-000001-chat", proc.stderr)

    def test_a_stamped_discard_row_passes_the_journal_scan(self):
        p = self.journal("discard", "CONTAMINATED: swapped; "
                                    "adjudicated@20260809 jk: swapped unified memory")
        proc = self.cli("--tsv", str(p))
        self.assertEqual(0, proc.returncode, proc.stderr + proc.stdout)


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
