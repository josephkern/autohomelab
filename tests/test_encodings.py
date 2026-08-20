"""Contract §2 — the `req_counts` and `knobs` encodings.

These two columns are the only free-form structure in a TSV row, so they are the only place a
row can be corrupted into unparseability. The tests are written round-trip-first (parse -> format
-> parse) so they do not depend on the implementation's internal mapping type.

`req_counts` field order is `ok/incomplete/errored` (contract §2 wording), NOT
`successful/errored/incomplete` — the example `c16:118/4/0` is 118 ok, 4 incomplete, 0 errored.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ahl_test import api

REQ_COUNTS_EXAMPLE = "c1:41/0/0;c16:118/4/0"
KNOBS_EXAMPLE = ("levels=1|16,max_s=180,seed=42,prompt=512,output=256,"
                 "stall=90,ltimeout=480,gllm=0.6.0")


class EncodingTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)

    def fns(self, kind):
        fmt = api.attr(self, self.mod, f"format_{kind}", f"{kind}_str", f"encode_{kind}",
                       f"{kind}_to_str", what=f"the §2 `{kind}` encoding")
        parse = api.attr(self, self.mod, f"parse_{kind}", f"{kind}_from_str", f"decode_{kind}",
                         what=f"the §2 `{kind}` decoding")
        return fmt, parse


class TestReqCounts(EncodingTestCase):
    def test_documented_example_round_trips(self):
        fmt, parse = self.fns("req_counts")
        self.assertEqual(REQ_COUNTS_EXAMPLE, fmt(parse(REQ_COUNTS_EXAMPLE)))

    def test_round_trip_is_idempotent(self):
        fmt, parse = self.fns("req_counts")
        once = fmt(parse(REQ_COUNTS_EXAMPLE))
        self.assertEqual(once, fmt(parse(once)))

    def test_na_round_trips(self):
        """§2: 'na when unknown (historical rows with no retained bundle)'."""
        fmt, parse = self.fns("req_counts")
        self.assertEqual("na", fmt(parse("na")))

    def test_empty_mapping_formats_as_na(self):
        """§2: 'Values are never empty — use na.'"""
        fmt, _ = self.fns("req_counts")
        self.assertEqual("na", fmt({}))

    def test_levels_stay_in_ascending_order(self):
        """Row-to-row diffs are useless if the level order is not stable."""
        fmt, parse = self.fns("req_counts")
        out = fmt(parse("c16:118/4/0;c1:41/0/0"))
        self.assertEqual(["c1", "c16"], [seg.split(":")[0] for seg in out.split(";")],
                         f"levels must be emitted low->high; got {out!r}")

    def test_no_tab_or_newline(self):
        fmt, parse = self.fns("req_counts")
        out = fmt(parse(REQ_COUNTS_EXAMPLE))
        self.assertNotIn("\t", out)
        self.assertNotIn("\n", out)

    def test_full_sweep_round_trips(self):
        fmt, parse = self.fns("req_counts")
        s = "c1:41/0/0;c4:80/1/0;c8:120/2/0;c16:118/4/0;c32:200/9/3"
        self.assertEqual(s, fmt(parse(s)))


class TestKnobs(EncodingTestCase):
    def test_documented_example_round_trips(self):
        """§2 value encoding (v1.1): 'No value may contain the pair separator. List values use
        `|` (`levels=1|16`), so a naive `split(",")` is always correct. v1.0's `levels=1,16`
        example was not round-trippable and is withdrawn.'"""
        fmt, parse = self.fns("knobs")
        self.assertEqual(KNOBS_EXAMPLE, fmt(parse(KNOBS_EXAMPLE)))

    def test_a_list_value_is_joined_with_the_pipe(self):
        """The encoder's side of the rule, with a real Python list — the round-trip tests below
        only ever hand it a pre-joined STRING, so they pass unchanged even if the joiner is put
        back to a comma. That is how `_LIST_SEP` went untested."""
        fmt, _ = self.fns("knobs")
        self.assertEqual("levels=1|16", fmt({"levels": [1, 16]}))
        self.assertEqual("levels=1|4|8|16|32", fmt({"levels": (1, 4, 8, 16, 32)}))

    def test_a_comma_inside_a_value_never_reaches_the_column(self):
        """Whatever the encoder does with a comma-bearing value, `split(",")` on the result must
        still recover every pair — that is the guarantee §2 buys."""
        fmt, _ = self.fns("knobs")
        out = fmt({"levels": "1,16", "max_s": 180})
        pairs = [c for c in out.split(",") if c]
        self.assertTrue(all("=" in c for c in pairs),
                        f"a naive split(',') must yield only k=v pairs; got {out!r}")
        self.assertEqual(2, len(pairs), f"two knobs, two pairs; got {out!r}")

    def test_levels_value_with_a_comma_survives(self):
        fmt, parse = self.fns("knobs")
        d = parse(KNOBS_EXAMPLE)
        got = fmt(d)
        self.assertIn("levels=1|16", got,
                      f"the levels list must not be shredded by the joiner; got {got!r}")
        self.assertIn("max_s=180", got, f"got {got!r}")
        self.assertIn("gllm=0.6.0", got, f"got {got!r}")

    def test_round_trip_is_idempotent(self):
        fmt, parse = self.fns("knobs")
        once = fmt(parse(KNOBS_EXAMPLE))
        self.assertEqual(once, fmt(parse(once)))

    def test_full_sweep_levels_round_trip(self):
        fmt, parse = self.fns("knobs")
        s = KNOBS_EXAMPLE.replace("levels=1|16", "levels=1|4|8|16|32")
        self.assertEqual(s, fmt(parse(s)))

    def test_key_order_is_stable(self):
        fmt, parse = self.fns("knobs")
        self.assertEqual(fmt(parse(KNOBS_EXAMPLE)), fmt(parse(KNOBS_EXAMPLE)))

    def test_no_tab_or_newline(self):
        fmt, parse = self.fns("knobs")
        out = fmt(parse(KNOBS_EXAMPLE))
        self.assertNotIn("\t", out)
        self.assertNotIn("\n", out)

    def test_a_hostile_value_cannot_break_the_tsv(self):
        """A knob value can come from the environment (MAX_SECONDS, NOTES-adjacent settings).
        Whatever the encoder does — escape, strip, or reject — it must not emit a raw tab or
        newline into a tab-separated row."""
        fmt, _ = self.fns("knobs")
        hostile = {"levels": "1,16", "note": "a\tb\nc"}
        try:
            out = fmt(hostile)
        except (ValueError, TypeError):
            return  # rejecting is an acceptable answer
        self.assertNotIn("\t", out, f"raw tab leaked into the TSV: {out!r}")
        self.assertNotIn("\n", out, f"raw newline leaked into the TSV: {out!r}")

    def test_empty_mapping_formats_as_na(self):
        fmt, _ = self.fns("knobs")
        self.assertEqual("na", fmt({}))


class TestAssessorEmitsParseableColumns(unittest.TestCase):
    """The columns the assessor actually writes must survive their own decoder."""

    def setUp(self):
        self.mod = api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_req_counts_from_a_real_run_round_trips(self):
        b = api.write_bundle(self.tmp / "b", {
            1: api.level_json(41, 0, 0, 20.0, rate=1),
            16: api.level_json(118, 0, 4, 200.0, rate=16)})
        v = api.assess(self, self.mod, b, [1, 16],
                       node_profile=api.FIXTURES / "node_profile_gb10.json")
        if v.req_counts is None:
            self.skipTest("assessor exposes no req_counts field")
        fmt = api.attr(self, self.mod, "format_req_counts", "req_counts_str", "encode_req_counts")
        parse = api.attr(self, self.mod, "parse_req_counts", "req_counts_from_str",
                         "decode_req_counts")
        s = str(v.req_counts)
        self.assertEqual(s, fmt(parse(s)), f"assessor emitted an unparseable req_counts: {s!r}")

    def test_req_counts_uses_the_documented_ok_incomplete_errored_order(self):
        b = api.write_bundle(self.tmp / "b2", {
            16: api.level_json(118, 0, 4, 200.0, rate=16)})   # 118 ok, 0 errored, 4 incomplete
        v = api.assess(self, self.mod, b, [16],
                       node_profile=api.FIXTURES / "node_profile_gb10.json")
        if v.req_counts is None:
            self.skipTest("assessor exposes no req_counts field")
        self.assertEqual("c16:118/4/0", str(v.req_counts),
                         "§2 spells the triple ok/incomplete/errored")


if __name__ == "__main__":
    unittest.main()
