"""The suite's reality check: real, minimized GuideLLM 0.6.0 bundles from this node.

Two jobs.

1. FALSE POSITIVES. A validity layer that flags healthy runs gets switched off within a week, so
   `real_healthy_chat` — an ordinary lean chat run from 20260816 — must come back `ok`. This test
   matters at least as much as the true-positive ones.
2. FIELD SHAPE. The synthetic fixtures in `ahl_test.api.level_json` are an invention; these are
   not. If GuideLLM's real output nests a count somewhere the implementation does not look, this
   is where it shows.

Provenance for every file: tests/fixtures/PROVENANCE.md.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api

GB10 = api.FIXTURES / "node_profile_gb10.json"


class RealBundleTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def load(self, name, levels, **kw):
        b = api.copy_fixture_bundle(name, self.tmp / name)
        kw.setdefault("node_profile", GB10)
        return b, api.assess(self, self.mod, b, levels, **kw)


class TestHealthyRunIsNotFlagged(RealBundleTestCase):
    """Inferact/Qwen3.8-27B-NVFP4 20260816-151632-chat: c1 ok=20/inc=1, c16 ok=183/inc=15."""

    def test_real_healthy_lean_run_is_ok(self):
        _, v = self.load("real_healthy_chat", [1, 16])
        self.assertEqual("ok", str(v.validity),
                         f"a normal, citable run must not be flagged; got {v}")

    def test_real_healthy_lean_run_keeps_status_measured(self):
        _, v = self.load("real_healthy_chat", [1, 16])
        self.assertEqual("measured", v.status, f"got {v}")

    def test_real_healthy_run_req_counts_are_read_from_the_real_json(self):
        _, v = self.load("real_healthy_chat", [1, 16])
        if v.req_counts is None:
            self.skipTest("assessor exposes no req_counts field")
        self.assertEqual("c1:20/1/0;c16:183/15/0", str(v.req_counts),
                         "counts come straight from metrics.request_totals of the real bundle")

    def test_real_healthy_run_is_ok_without_a_bandwidth_figure_too(self):
        _, v = self.load("real_healthy_chat", [1, 16],
                         node_profile=api.FIXTURES / "node_profile_no_bw.json")
        self.assertEqual("ok", str(v.validity), f"got {v}")


class TestRealDefectA(RealBundleTestCase):
    """Contract §0 (a): Inferact 20260817-201312-coder, c32 averaged over 2 requests."""

    def test_two_request_c32_is_void(self):
        _, v = self.load("real_thin_coder", [1, 32])
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")

    def test_the_c1_of_the_same_run_is_also_below_min_data(self):
        """ok=3 at c1 — the whole coder row was never data, not just its c32."""
        _, v = self.load("real_thin_coder", [1])
        self.assertIn("no_data", v.tokens, f"got {v}")


class TestRealDefectB(RealBundleTestCase):
    """Contract §0 (b): unsloth/Qwen3.8-27B-NVFP4 20260818-135818-chat, tps_c16 = 449358.18."""

    def test_dead_endpoint_c16_is_over_roofline(self):
        _, v = self.load("real_dead_endpoint", [1, 16])
        self.assertIn("over_roofline", v.tokens, f"got {v}")

    def test_dead_endpoint_c16_is_also_flagged_errored(self):
        """ok=16 against errored=112069 — 99.99% errored."""
        _, v = self.load("real_dead_endpoint", [1, 16])
        self.assertIn("errored", v.tokens, f"got {v}")

    def test_dead_endpoint_c16_is_also_low_sample(self):
        _, v = self.load("real_dead_endpoint", [1, 16])
        self.assertIn("low_sample", v.tokens, f"16 successful < 20; got {v}")

    def test_the_row_as_written_was_a_crash_so_crash_wins(self):
        """The real row carries status=crash. §5: the verdict is recorded, the status is not."""
        _, v = self.load("real_dead_endpoint", [1, 16], status="crash")
        self.assertEqual("crash", v.status, f"got {v}")
        self.assertIn("over_roofline", v.tokens, f"got {v}")

    def test_without_the_crash_marker_it_would_be_void(self):
        _, v = self.load("real_dead_endpoint", [1, 16])
        self.assertEqual("void", v.status, f"got {v}")

    def test_the_healthy_c1_of_that_run_alone_is_ok(self):
        """c1 was ok=20 / 28.99 tok/s — the best c1 in that bracket. The layer must not condemn
        a level that was fine just because a sibling level died."""
        _, v = self.load("real_dead_endpoint", [1])
        self.assertEqual("ok", str(v.validity), f"got {v}")


class TestRealDefectC(RealBundleTestCase):
    """Contract §0 (c): the level json that never landed."""

    def test_deleting_a_real_level_json_yields_no_data(self):
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "gap")
        (b / "level_c16.json").unlink()
        v = api.assess(self, self.mod, b, [1, 16], node_profile=GB10)
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")

    def test_truncating_a_real_level_json_yields_no_data(self):
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "trunc")
        target = b / "level_c16.json"
        target.write_text(target.read_text()[:2000])   # a killed writer leaves a partial file
        v = api.assess(self, self.mod, b, [1, 16], node_profile=GB10)
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")


class TestFixtureIntegrity(unittest.TestCase):
    """Guards the fixtures themselves — a silently edited fixture would make the suite lie.

    These run even before the implementation lands, so `tests/run.sh` is not vacuously green.
    """

    EXPECTED = {
        ("real_healthy_chat", 1): (20, 0, 1),
        ("real_healthy_chat", 16): (183, 0, 15),
        ("real_thin_coder", 1): (3, 0, 0),
        ("real_thin_coder", 32): (2, 0, 31),
        ("real_dead_endpoint", 1): (20, 0, 0),
        ("real_dead_endpoint", 16): (16, 112069, 0),
    }

    def test_counts_are_the_real_recorded_numbers(self):
        import json
        for (bundle, level), (ok, err, inc) in self.EXPECTED.items():
            p = api.FIXTURES / bundle / f"level_c{level}.json"
            with self.subTest(bundle=bundle, level=level):
                rt = json.loads(p.read_text())["benchmarks"][0]["metrics"]["request_totals"]
                self.assertEqual({"successful": ok, "errored": err, "incomplete": inc,
                                  "total": ok + err + inc}, rt)

    def test_the_449358_number_is_intact(self):
        import json
        p = api.FIXTURES / "real_dead_endpoint" / "level_c16.json"
        tps = json.loads(p.read_text())["benchmarks"][0]["metrics"][
            "output_tokens_per_second"]["successful"]["mean"]
        self.assertAlmostEqual(449358.18, tps, places=1)

    def test_fixtures_are_guidellm_0_6_0(self):
        """The pinned driver. If this changes, every fixture needs regenerating."""
        import json
        for p in sorted(api.FIXTURES.glob("real_*/level_c*.json")):
            with self.subTest(fixture=p.name, bundle=p.parent.name):
                self.assertEqual("0.6.0",
                                 json.loads(p.read_text())["metadata"]["guidellm_version"])

    def test_fixtures_stay_small(self):
        """Charter rule 5: raw bundles are never committed — only minimized extracts."""
        total = sum(p.stat().st_size for p in api.FIXTURES.rglob("*") if p.is_file())
        self.assertLess(total, 256 * 1024, f"tests/fixtures is {total} bytes — minimize harder")

    def test_node_profile_fixtures_differ_only_in_mem_bw(self):
        import json
        with_bw = json.loads((api.FIXTURES / "node_profile_gb10.json").read_text())
        without = json.loads((api.FIXTURES / "node_profile_no_bw.json").read_text())
        self.assertEqual(273, with_bw["gpu"].pop("mem_bw_gbs"))
        self.assertNotIn("mem_bw_gbs", without["gpu"])
        self.assertEqual(without, with_bw)


if __name__ == "__main__":
    unittest.main()
