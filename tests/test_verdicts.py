"""Contract §3 — verdict tokens, computed from the per-level GuideLLM JSON.

Every threshold in the table is a test case here. Where a number is a boundary, BOTH sides of it
are asserted, because the whole value of this layer is that it fires exactly where the spec says.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api

GB10 = api.FIXTURES / "node_profile_gb10.json"


class VerdictTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def bundle(self, levels, name="bundle"):
        return api.write_bundle(self.tmp / name, levels)

    def assess(self, levels_on_disk, run_levels, **kw):
        kw.setdefault("node_profile", GB10)
        return api.assess(self, self.mod, self.bundle(levels_on_disk), run_levels, **kw)

    def healthy(self, tps=20.0, rate=1, successful=41):
        return api.level_json(successful=successful, errored=0, incomplete=0, tps=tps, rate=rate)


class TestHistoricalDefects(VerdictTestCase):
    """Contract §0: the three real rows that were written as `status=measured` and were wrong."""

    def test_a_two_completed_requests_is_no_data(self):
        """(a) a c32 averaged over 2 completed requests -> no_data, status floor void."""
        v = self.assess({1: self.healthy(), 32: api.level_json(2, 0, 31, 256.19, rate=32)},
                        [1, 32])
        self.assertIn("no_data", v.tokens, f"2 successful requests must be no_data; got {v}")
        self.assertEqual("void", v.status, f"no_data is fatal -> void (§5); got {v}")

    def test_b_impossible_throughput_is_over_roofline(self):
        """(b) 449,358 tok/s on a 273 GB/s node -> over_roofline, status floor void."""
        v = self.assess({1: self.healthy(tps=28.99, successful=20),
                         16: api.level_json(16, 112069, 0, 449358.18, rate=16)},
                        [1, 16])
        self.assertIn("over_roofline", v.tokens,
                      f"449358 tok/s implies 0.0006 GB/token on a 273 GB/s box; got {v}")
        self.assertEqual("void", v.status, f"over_roofline is fatal -> void (§5); got {v}")

    def test_c_missing_level_json_is_no_data(self):
        """(c) a level that was RUN but whose level_c<N>.json never landed -> no_data / void."""
        v = self.assess({1: self.healthy()}, [1, 16])  # c16 declared run, file absent
        self.assertIn("no_data", v.tokens,
                      f"a run level with no level_c16.json must be no_data; got {v}")
        self.assertEqual("void", v.status)

    def test_c_unparseable_level_json_is_no_data(self):
        v = self.assess({1: self.healthy(), 16: '{"benchmarks": [truncated'}, [1, 16])
        self.assertIn("no_data", v.tokens, f"unparseable JSON must be no_data; got {v}")
        self.assertEqual("void", v.status)

    def test_c_empty_level_json_is_no_data(self):
        v = self.assess({1: self.healthy(), 16: ""}, [1, 16])
        self.assertIn("no_data", v.tokens, f"a zero-byte level json must be no_data; got {v}")
        self.assertEqual("void", v.status)


class TestSampleCountBoundaries(VerdictTestCase):
    """AHL_MIN_DATA=5 (fatal) and AHL_MIN_SUCCESSFUL=20 (suspect), both strict `<`."""

    def _tokens_for(self, successful):
        return self.assess({1: self.healthy(), 16: api.level_json(successful, 0, 0, 200.0, 16)},
                           [1, 16])

    def test_successful_4_is_no_data(self):
        v = self._tokens_for(4)
        self.assertIn("no_data", v.tokens, f"4 < MIN_DATA(5); got {v}")
        self.assertEqual("void", v.status)

    def test_successful_5_is_not_no_data(self):
        v = self._tokens_for(5)
        self.assertNotIn("no_data", v.tokens,
                         f"the rule is `successful < 5`, so 5 is data; got {v}")

    def test_successful_5_is_low_sample(self):
        v = self._tokens_for(5)
        self.assertIn("low_sample", v.tokens, f"5 < MIN_SUCCESSFUL(20); got {v}")
        self.assertEqual("suspect", v.status, f"low_sample is suspect-severity (§5); got {v}")

    def test_successful_19_is_low_sample(self):
        v = self._tokens_for(19)
        self.assertIn("low_sample", v.tokens, f"19 < MIN_SUCCESSFUL(20); got {v}")
        self.assertNotIn("no_data", v.tokens)
        self.assertEqual("suspect", v.status)

    def test_successful_20_is_clean(self):
        v = self._tokens_for(20)
        self.assertEqual("ok", v.validity,
                         f"the rule is `successful < 20`, so exactly 20 passes; got {v}")
        self.assertEqual("measured", v.status)

    def test_no_data_and_low_sample_are_mutually_exclusive(self):
        """§3: 'report the more severe' — a 3-request level is no_data ONLY."""
        v = self._tokens_for(3)
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertNotIn("low_sample", v.tokens,
                         f"no_data and low_sample are mutually exclusive; got {v}")

    def test_thresholds_are_env_overridable(self):
        """§3 names AHL_MIN_DATA / AHL_MIN_SUCCESSFUL, so they must be readable from the env."""
        mod = api.load_validity({"AHL_MIN_DATA": "10", "AHL_MIN_SUCCESSFUL": "10"})
        if mod is None:
            self.skipTest("scripts/lib/validity.py not implemented yet")
        b = self.bundle({1: self.healthy(), 16: api.level_json(8, 0, 0, 200.0, 16)}, "envcase")
        v = api.assess(self, mod, b, [1, 16], node_profile=GB10)
        self.assertIn("no_data", v.tokens,
                      f"with AHL_MIN_DATA=10, 8 successful must be no_data; got {v}")


class TestMonotonicity(VerdictTestCase):
    """§3: `nonmonotonic` iff a higher level is MORE THAN 10% below a lower one."""

    def _at(self, c16_tps):
        return self.assess(
            {8: api.level_json(60, 0, 0, 100.0, rate=8),
             16: api.level_json(60, 0, 0, c16_tps, rate=16)}, [8, 16])

    def test_drop_of_9_9_percent_is_not_flagged(self):
        v = self._at(90.1)
        self.assertNotIn("nonmonotonic", v.tokens,
                         f"a 9.9% drop is plateau/noise on a bandwidth-bound box; got {v}")
        self.assertEqual("ok", v.validity, f"got {v}")

    def test_drop_of_10_1_percent_is_flagged(self):
        v = self._at(89.9)
        self.assertIn("nonmonotonic", v.tokens, f"a 10.1% drop is a real inversion; got {v}")
        self.assertEqual("suspect", v.status, f"nonmonotonic is suspect-severity (§5); got {v}")

    def test_documented_coder_inversion_is_not_flagged_by_monotonicity(self):
        """§3 implementer note: c8 70.88 > c16 68.88 (2.8%) is caught by no_data, NOT here.

        Sample counts are healthy in this variant precisely to isolate the monotonicity rule.
        """
        v = self.assess({8: api.level_json(60, 0, 0, 70.88, rate=8),
                         16: api.level_json(60, 0, 0, 68.88, rate=16)}, [8, 16])
        self.assertNotIn("nonmonotonic", v.tokens,
                         f"2.8% is inside the deliberately loose 10% band; got {v}")


class TestErroredRatio(VerdictTestCase):
    """§3: `errored` iff errored > 10% of (successful + errored)."""

    def _at(self, successful, errored):
        return self.assess(
            {1: self.healthy(),
             16: api.level_json(successful, errored, 0, 200.0, rate=16)}, [1, 16])

    def test_9_9_percent_errored_is_not_flagged(self):
        v = self._at(901, 99)  # 99/1000
        self.assertNotIn("errored", v.tokens, f"9.9% <= 10%; got {v}")
        self.assertEqual("ok", v.validity, f"got {v}")

    def test_10_1_percent_errored_is_flagged(self):
        v = self._at(899, 101)  # 101/1000
        self.assertIn("errored", v.tokens, f"10.1% > 10%; got {v}")
        self.assertEqual("suspect", v.status, f"errored is suspect-severity (§5); got {v}")

    def test_ratio_denominator_excludes_incomplete(self):
        """§3 spells the denominator as `successful + errored`; incomplete must not dilute it.

        1000 incomplete requests alongside 899/101 would drop the ratio to 5.3% under a
        `total`-based denominator and silently hide a half-broken endpoint.
        """
        v = self.assess({1: self.healthy(),
                         16: api.level_json(899, 101, 1000, 200.0, rate=16)}, [1, 16])
        self.assertIn("errored", v.tokens,
                      f"denominator is successful+errored, not total; got {v}")


class TestUnrunLevelsAreSkipped(VerdictTestCase):
    """§3: 'Verdicts are computed over RUN levels only; na (unrun) levels are skipped, never
    treated as zero.' This is the rule a naive implementation gets wrong."""

    def test_lean_run_is_ok_not_no_data(self):
        """The routine matrix is LEVELS_SET=1,16. c4/c8/c32 were never run."""
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         16: api.level_json(118, 0, 4, 200.0, rate=16)}, [1, 16])
        self.assertEqual("ok", v.validity,
                         f"a healthy lean run must be ok, not no_data for c4/c8/c32; got {v}")
        self.assertEqual("measured", v.status)

    def test_unrun_levels_do_not_appear_in_req_counts(self):
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         16: api.level_json(118, 0, 4, 200.0, rate=16)}, [1, 16])
        if v.req_counts is None:
            self.skipTest("assessor exposes no req_counts field")
        rc = str(v.req_counts)
        for unrun in ("c4", "c8", "c32"):
            self.assertNotIn(unrun + ":", rc,
                             f"unrun level {unrun} must not be reported; got {rc!r}")

    def test_unrun_level_is_not_a_zero_for_monotonicity(self):
        """c1 then c32 only: the absent c4/c8/c16 must not read as 0 tok/s inversions."""
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         32: api.level_json(90, 0, 0, 300.0, rate=32)}, [1, 32])
        self.assertNotIn("nonmonotonic", v.tokens,
                         f"skipped levels are not zeros; got {v}")
        self.assertEqual("ok", v.validity, f"got {v}")

    def test_a_single_run_level_is_assessable(self):
        v = self.assess({16: api.level_json(118, 0, 4, 200.0, rate=16)}, [16])
        self.assertEqual("ok", v.validity, f"one healthy level is a valid lean run; got {v}")

    def test_present_but_unrun_json_is_ignored(self):
        """A stale level_c8.json left in the bundle from a previous shape must not be scored.

        The run-level list, not the directory listing, defines what was measured.
        """
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         8: api.level_json(2, 0, 40, 999.0, rate=8),   # stale, 2 requests
                         16: api.level_json(118, 0, 4, 200.0, rate=16)}, [1, 16])
        self.assertEqual("ok", v.validity,
                         f"only declared run levels are scored; got {v}")


class TestVerdictString(VerdictTestCase):
    """§2/§3: `validity` is `ok` or a `+`-joined token list, and is never empty."""

    def test_clean_run_is_the_literal_string_ok(self):
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         16: api.level_json(118, 0, 4, 200.0, rate=16)}, [1, 16])
        self.assertEqual("ok", str(v.validity))

    def test_multiple_tokens_are_plus_joined(self):
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         16: api.level_json(10, 5, 0, 200.0, rate=16)}, [1, 16])
        s = str(v.validity)
        self.assertIn("+", s, f"low_sample and errored must both be reported; got {s!r}")
        self.assertNotIn("ok", s.split("+"), f"`ok` must not appear beside real tokens; got {s!r}")

    def test_validity_value_is_tsv_safe(self):
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         16: api.level_json(10, 5, 0, 200.0, rate=16)}, [1, 16])
        s = str(v.validity)
        self.assertNotIn("\t", s)
        self.assertNotIn("\n", s)
        self.assertNotEqual("", s, "§2: values are never empty — use `na`")


if __name__ == "__main__":
    unittest.main()
