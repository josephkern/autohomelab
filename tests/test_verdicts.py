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
    """Contract §0: the real rows that were written as `status=measured` and were wrong.

    Only defects (a) and (b) live here. **Defect (c) — the spec-decode config scored by a
    loglikelihood task returning NaN for 56,168 requests — is a GATE 2 failure and NOTHING in
    this module can catch it** (§0 "Scope limit"; v1.2 A9 brings it into scope for `eval.sh`).
    Three tests used to be named `test_c_*` here while actually testing a missing level JSON,
    so a reader running the suite saw all three motivating defects green. They are renamed
    below to say what they test. Gate-2 coverage for (c) is F5's, in its own module.
    """

    def test_a_two_completed_requests_is_no_data(self):
        """(a) a c32 averaged over 2 completed requests -> no_data, status floor void."""
        v = self.assess({1: self.healthy(), 32: api.level_json(2, 0, 31, 256.19, rate=32)},
                        [1, 32])
        self.assertIn("no_data", v.tokens, f"2 successful requests must be no_data; got {v}")
        self.assertEqual("void", v.status, f"no_data is fatal -> void (§5); got {v}")
        self.assertIn("no_data@c32", v.tagged,
                      f"§3: the token names the level it refers to; got {v.tagged}")

    def test_b_impossible_throughput_is_over_roofline(self):
        """(b) 449,358 tok/s on a 273 GB/s node -> over_roofline, status floor void."""
        v = self.assess({1: self.healthy(tps=28.99, successful=20),
                         16: api.level_json(16, 112069, 0, 449358.18, rate=16)},
                        [1, 16])
        self.assertIn("over_roofline", v.tokens,
                      f"449358 tok/s implies 0.0097 GB/token on a 273 GB/s box; got {v}")
        self.assertEqual("void", v.status, f"over_roofline is fatal -> void (§5); got {v}")
        self.assertIn("over_roofline@c16", v.tagged, f"got {v.tagged}")


class TestMissingLevelJson(VerdictTestCase):
    """§3: 'a run level whose `level_c<N>.json` is missing/unparseable' -> `no_data`, fatal.

    NOT contract §0 defect (c) — that is the Gate-2 NaN eval, which no rule in this file reads.
    """

    def test_missing_level_json_is_no_data(self):
        v = self.assess({1: self.healthy()}, [1, 16])  # c16 declared run, file absent
        self.assertIn("no_data", v.tokens,
                      f"a run level with no level_c16.json must be no_data; got {v}")
        self.assertEqual("void", v.status)
        self.assertIn("no_data@c16", v.tagged, f"got {v.tagged}")

    def test_unparseable_level_json_is_no_data(self):
        v = self.assess({1: self.healthy(), 16: '{"benchmarks": [truncated'}, [1, 16])
        self.assertIn("no_data", v.tokens, f"unparseable JSON must be no_data; got {v}")
        self.assertEqual("void", v.status)

    def test_empty_level_json_is_no_data(self):
        v = self.assess({1: self.healthy(), 16: ""}, [1, 16])
        self.assertIn("no_data", v.tokens, f"a zero-byte level json must be no_data; got {v}")
        self.assertEqual("void", v.status)

    def test_missing_level_renders_as_na_in_req_counts(self):
        """§2: 'A level that ran but produced no parseable JSON renders `c16:na`.'"""
        v = self.assess({1: self.healthy()}, [1, 16])
        self.assertIn("c16:na", str(v.req_counts), f"got {v}")


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
        # require_validity keeps the override in os.environ for the whole test: the library
        # reads AHL_* at call time, not at import time.
        mod = api.require_validity(self, {"AHL_MIN_DATA": "10", "AHL_MIN_SUCCESSFUL": "10"})
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


class TestLevelTagging(VerdictTestCase):
    """§3 v1.1: 'Tokens carry the level they refer to: `low_sample@c1`, `no_data@c32`,
    `survivorship@c16`. Only `ok` and `nonmonotonic` are row-wide and untagged.'

    Asserted on `.tagged` — the tokens EXACTLY as emitted. The old suite only ever asserted on
    a helper that returned the tagged token *and* its bare base, so deleting `tag_verdict`
    entirely left all 121 tests green (v1.2 A8). Every assertion here fails if tagging goes.
    """

    def test_a_thin_low_level_is_tagged_there_not_at_c16(self):
        """c4's floor is min(20, 4*4) = 16, so 15 requests is thin at c4 and the healthy c16
        objective beside it must stay unflagged."""
        v = self.assess({4: api.level_json(15, 0, 0, 60.0, rate=4),
                         16: api.level_json(200, 0, 0, 300.0, rate=16)}, [4, 16])
        self.assertEqual({"low_sample@c4"}, v.tagged,
                         f"the c4 stage is thin, the c16 objective is not; got {v.tagged}")

    def test_the_same_rule_at_c16_is_tagged_c16(self):
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1),
                         16: api.level_json(19, 0, 0, 300.0, rate=16)}, [1, 16])
        self.assertEqual({"low_sample@c16"}, v.tagged, f"got {v.tagged}")

    def test_two_levels_produce_two_distinct_tokens(self):
        v = self.assess({1: api.level_json(2, 0, 0, 20.0, rate=1),
                         16: api.level_json(19, 0, 0, 300.0, rate=16)}, [1, 16])
        self.assertEqual({"no_data@c1", "low_sample@c16"}, v.tagged, f"got {v.tagged}")
        self.assertEqual({1}, v.levels_of("no_data"), f"got {v.tagged}")
        self.assertEqual({16}, v.levels_of("low_sample"), f"got {v.tagged}")

    def test_nonmonotonic_stays_bare(self):
        """§3: `nonmonotonic` is row-wide, so tagging it would be wrong in the other direction."""
        v = self.assess({8: api.level_json(60, 0, 0, 100.0, rate=8),
                         16: api.level_json(60, 0, 0, 50.0, rate=16)}, [8, 16])
        self.assertIn("nonmonotonic", v.tagged,
                      f"a row-wide verdict is emitted untagged; got {v.tagged}")
        self.assertEqual({None}, v.levels_of("nonmonotonic"), f"got {v.tagged}")

    def test_a_hung_level_is_named_by_its_token(self):
        """§3: 'A hung level is scored (and its token names it), not skipped' — this is what
        makes a crash row say WHICH level wedged."""
        v = self.assess({1: api.level_json(41, 0, 0, 20.0, rate=1)}, [1, 16],
                        tps={1: "20.0", 16: "hang"}, status="crash")
        self.assertIn("no_data@c16", v.tagged,
                      f"the wedged level must be named in the verdict; got {v.tagged}")

    def test_tagging_survives_the_format_parse_round_trip(self):
        """The tag has to reach results.tsv, not just the in-memory verdict."""
        fmt = api.attr(self, self.mod, "format_validity", what="the §2 validity encoding")
        parse = api.attr(self, self.mod, "parse_validity", what="the §2 validity decoding")
        self.assertEqual(["low_sample@c1", "no_data@c32"],
                         sorted(parse(fmt(["no_data@c32", "low_sample@c1"]))))


class TestAdjacencyOnly(VerdictTestCase):
    """§3 v1.1: '`nonmonotonic` is adjacent-only — each run level against the previous run
    level, NEVER pairwise across the whole curve. This box legitimately plateaus at high
    concurrency; pairwise-all would flag gentle decay as an inversion.'

    Every case here needs 3+ levels: at two levels adjacent and pairwise-all are identical, so
    a suite that only ever tested two levels could not tell the two semantics apart — which is
    exactly how reverting to `itertools.combinations` stayed green.
    """

    def curve(self, *tps):
        levels = (1, 4, 8, 16, 32)[: len(tps)]
        return self.assess(
            {lv: api.level_json(60, 0, 0, t, rate=lv) for lv, t in zip(levels, tps)},
            list(levels))

    def test_gentle_decay_across_three_levels_is_not_nonmonotonic(self):
        """100 -> 95 -> 88: every ADJACENT step is inside the 10% band, but c8 vs c1 is a
        12% drop, so pairwise-all fires and adjacent-only does not."""
        v = self.curve(100.0, 95.0, 88.0)
        self.assertNotIn("nonmonotonic", v.tokens,
                         f"adjacent steps are -5.0% and -7.4%, both legal; got {v}")
        self.assertEqual("ok", str(v.validity), f"got {v}")

    def test_gentle_decay_across_five_levels_is_not_nonmonotonic(self):
        """The real plateau shape on a bandwidth-bound box: the c1-vs-c32 pair is -32%."""
        v = self.curve(100.0, 95.0, 90.5, 86.0, 82.0)
        self.assertNotIn("nonmonotonic", v.tokens,
                         f"no adjacent step exceeds 10%; got {v}")

    def test_one_adjacent_inversion_is_still_caught(self):
        """Adjacent-only must not become 'never fires': a real 15% step still trips it."""
        v = self.curve(100.0, 95.0, 80.0)
        self.assertIn("nonmonotonic", v.tokens,
                      f"c8 is 15.8% below c4, an adjacent inversion; got {v}")
        self.assertEqual("suspect", v.status, f"got {v}")

    def test_a_recovered_dip_is_caught_at_the_dip(self):
        """100 -> 80 -> 100: pairwise c1-vs-c16 is fine, the adjacent c4 step is not."""
        v = self.curve(100.0, 80.0, 100.0)
        self.assertIn("nonmonotonic", v.tokens, f"got {v}")


class TestUnrunVersusHung(VerdictTestCase):
    """§3: 'A level is RUN if the journal published a cell OR a bundle file exists — the union.
    Unrun levels are skipped, never scored as zero. A hung level IS scored.'

    The distinction rides entirely on whether the results.tsv cell is `na` or `hang`, so these
    tests pass the raw cells the way bench.sh does. Collapsing the two (a `_cell_published`
    that always answers True) turns a never-attempted level into a fatal `no_data`, which would
    void every lean `LEVELS_SET=1,16` row in the project.
    """

    ONLY_C1 = {1: api.level_json(41, 0, 0, 20.0, rate=1)}

    def test_na_cell_with_no_json_is_dropped(self):
        v = self.assess(dict(self.ONLY_C1), [1, 4, 8, 16, 32],
                        tps={1: "20.0", 4: "na", 8: "na", 16: "na", 32: "na"})
        self.assertEqual("ok", str(v.validity),
                         f"c4/c8/c16/c32 were never attempted; got {v}")
        self.assertEqual("c1:41/0/0", str(v.req_counts), f"got {v}")

    def test_hang_cell_with_no_json_is_scored(self):
        v = self.assess(dict(self.ONLY_C1), [1, 16],
                        tps={1: "20.0", 16: "hang"})
        self.assertIn("no_data", v.tokens,
                      f"a level that wedged left no json but WAS run; got {v}")
        self.assertIn("c16:na", str(v.req_counts), f"got {v}")

    def test_the_two_cases_differ(self):
        """Same bundle, same declared levels — only the cell differs. If these two agree, the
        `na` vs `hang` distinction has been collapsed."""
        unrun = self.assess(dict(self.ONLY_C1), [1, 16], tps={1: "20.0", 16: "na"})
        hung = self.assess(dict(self.ONLY_C1), [1, 16], tps={1: "20.0", 16: "hang"})
        self.assertNotEqual(str(unrun.validity), str(hung.validity),
                            f"`na` and `hang` must not grade alike; both {unrun.validity!r}")

    def test_a_published_number_marks_the_level_run_even_without_json(self):
        """The union rule's other half: a journal cell carrying a real number means the level
        ran, so a vanished json is `no_data`, not a silent skip."""
        v = self.assess(dict(self.ONLY_C1), [1, 16], tps={1: "20.0", 16: "151.5"})
        self.assertIn("no_data", v.tokens, f"got {v}")


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
