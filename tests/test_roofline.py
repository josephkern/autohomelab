"""Contract §4 — the physical ceiling.

    ceiling(level) = SAFETY * level * (mem_bw_GB_s / bytes_per_token_GB)
    SAFETY = 2.0, bytes_per_token_GB falls back to AHL_MIN_MODEL_GB = 1.0

On the GB10 fixture (273 GB/s) that is 546 tok/s at c1 and 8736 at c16 — deliberately loose. The
bound exists to refute the physically impossible, so the tests here check both that it catches
449,358 and that it does NOT touch an absurd-but-under-ceiling number.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api

GB10 = api.FIXTURES / "node_profile_gb10.json"          # gpu.mem_bw_gbs = 273
NO_BW = api.FIXTURES / "node_profile_no_bw.json"        # the profile as it exists today


class RooflineTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0

    def at(self, level, tps, *, profile=GB10, successful=60, **kw):
        self.n += 1
        b = api.write_bundle(self.tmp / f"b{self.n}",
                             {level: api.level_json(successful, 0, 0, tps, rate=level)})
        return api.assess(self, self.mod, b, [level], node_profile=profile, **kw)


class TestCeiling(RooflineTestCase):
    def test_just_under_c16_ceiling_passes(self):
        v = self.at(16, 8735.0)   # ceiling = 2.0 * 16 * 273 / 1.0 = 8736
        self.assertNotIn("over_roofline", v.tokens,
                         f"8735 < 8736 must pass — the bound is loose on purpose; got {v}")

    def test_just_over_c16_ceiling_fails(self):
        v = self.at(16, 8737.0)
        self.assertIn("over_roofline", v.tokens, f"8737 > 8736; got {v}")

    def test_c1_ceiling_scales_with_level(self):
        """The ceiling is per-level: 546 at c1, so 600 tok/s at c1 is impossible while the same
        600 at c16 is merely implausible."""
        self.assertIn("over_roofline", self.at(1, 600.0).tokens)
        self.assertNotIn("over_roofline", self.at(16, 600.0).tokens)

    def test_the_449358_row_is_over_roofline(self):
        v = self.at(16, 449358.18, successful=16)
        self.assertIn("over_roofline", v.tokens, f"contract §0 defect (b); got {v}")

    def test_over_roofline_is_fatal(self):
        v = self.at(16, 449358.18)
        self.assertEqual("void", v.status, f"§3 marks over_roofline fatal -> §5 void; got {v}")


class TestBandwidthAbsent(RooflineTestCase):
    """§4: 'If mem_bw_gbs is absent from the node profile, the check is SKIPPED ... never invent
    a bandwidth number.' A skipped check must not become a silent pass-with-a-guess either way."""

    def test_missing_mem_bw_skips_the_check(self):
        v = self.at(16, 449358.18, profile=NO_BW)
        self.assertNotIn("over_roofline", v.tokens,
                         f"no mem_bw_gbs in the profile -> roofline is skipped; got {v}")

    def test_missing_mem_bw_does_not_void_the_row(self):
        v = self.at(16, 449358.18, profile=NO_BW)
        self.assertNotEqual("void", v.status,
                            f"a skipped check is not a failed check; got {v}")

    def test_no_profile_at_all_skips_the_check(self):
        v = self.at(16, 449358.18, profile=None)
        self.assertNotIn("over_roofline", v.tokens,
                         f"no node profile -> no bandwidth -> skip; got {v}")

    def test_other_verdicts_still_run_without_bandwidth(self):
        """Skipping the roofline must not short-circuit the sample-count checks."""
        v = self.at(16, 449358.18, profile=NO_BW, successful=2)
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertEqual("void", v.status)


class TestBytesPerToken(RooflineTestCase):
    """§4: when the model's active weight bytes/token is known, the bound tightens.

    21.18 GB/token is this repo's own measured figure for the FF711 dense Q5_K_M 27B (AGENTS.md
    lab notes), giving a c1 ceiling of 2.0 * 273 / 21.18 = 25.8 tok/s.
    """

    def test_known_bytes_per_token_tightens_the_bound(self):
        over = self.at(1, 30.0, bytes_per_token_gb=21.18)
        self.assertIn("over_roofline", over.tokens,
                      f"30 tok/s > 25.8 ceiling at 21.18 GB/token; got {over}")

    def test_known_bytes_per_token_still_admits_real_measurements(self):
        ok = self.at(1, 20.0, bytes_per_token_gb=21.18)
        self.assertNotIn("over_roofline", ok.tokens,
                         f"20 tok/s is under the 25.8 ceiling — a real FF711 number; got {ok}")


class TestConstants(unittest.TestCase):
    """The §4 defaults are named quantities; they must be inspectable, not buried in a literal."""

    def setUp(self):
        self.mod = api.require_validity(self)

    def test_safety_default_is_2(self):
        val = api.attr(self, self.mod, "SAFETY", "ROOFLINE_SAFETY", "AHL_SAFETY",
                       what="the §4 SAFETY factor")
        self.assertEqual(2.0, float(val))

    def test_min_model_gb_default_is_1(self):
        val = api.attr(self, self.mod, "MIN_MODEL_GB", "AHL_MIN_MODEL_GB", "DEFAULT_MODEL_GB",
                       what="the §4 bytes/token fallback")
        self.assertEqual(1.0, float(val))

    def test_min_data_default_is_5(self):
        val = api.attr(self, self.mod, "MIN_DATA", "AHL_MIN_DATA", what="the §3 no_data floor")
        self.assertEqual(5, int(val))

    def test_min_successful_default_is_20(self):
        val = api.attr(self, self.mod, "MIN_SUCCESSFUL", "AHL_MIN_SUCCESSFUL",
                       what="the §3 low_sample floor")
        self.assertEqual(20, int(val))


if __name__ == "__main__":
    unittest.main()
