"""Contract **v1.2** — the ten post-verification amendments (docs/validity-contract.md).

"Where v1.2 differs from v1.1, v1.2 wins." Every rule v1.2 changed is pinned here, and where it
changed a rule that already existed, BOTH directions are asserted: the new form must fire where
the spec says, and the withdrawn form must NOT fire where the spec withdrew it. A test that only
asserts the new behaviour cannot tell a correct implementation from one that kept both rules.

Covered: A1 (token clause removed) · A2 (survivorship redefined) · A3 (`no_output`) ·
A4 (`errored` escalates to fatal) · A5 (`na` is never `ok`) · A10 (CLI == `assess_bundle`).
A6 (bench.sh wiring) is in test_bench_enforcement.py; A7/A8 in test_wiring.py and mutate.sh.
"""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ahl_test import api

GB10 = api.FIXTURES / "node_profile_gb10.json"
NO_BW = api.FIXTURES / "node_profile_no_bw.json"


class V12TestCase(unittest.TestCase):
    def setUp(self):
        self.mod = api.require_validity(self)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.n = 0

    def one(self, level, *, profile=NO_BW, status="measured", **kw):
        """Assess a bundle holding exactly ONE level, so no row-wide rule can confound it."""
        self.n += 1
        b = api.write_bundle(self.tmp / f"b{self.n}",
                             {level: api.level_json(rate=level, **kw)})
        return api.assess(self, self.mod, b, [level], node_profile=profile, status=status)

    def raw(self, level, payload, *, profile=NO_BW, status="measured"):
        self.n += 1
        b = api.write_bundle(self.tmp / f"b{self.n}", {level: payload})
        return api.assess(self, self.mod, b, [level], node_profile=profile, status=status)


# ─────────────────────────────────────────────────────────────────────────────────────────────
# A1 — the token-budget clause is REMOVED
# ─────────────────────────────────────────────────────────────────────────────────────────────
class TestA1TokenClauseRemoved(V12TestCase):
    """A1: '`low_sample` is now solely `successful < max(AHL_MIN_DATA, min(20, 4*level))`.'

    The withdrawn clause was `successful * mean_output_tokens < 2048`. It fired alone on 3 of
    693 bundles, all false positives, and — because coder completions carry ~1000 output tokens
    — **3 requests cleared it**, so it approved 10 of the 15 genuinely starved levels. Any
    implementation that still consults an output-token budget fails the tests below.
    """

    def test_the_request_floor_is_the_whole_rule(self):
        fn = api.attr(self, self.mod, "min_requests_for_level", "low_sample_floor",
                      what="the A1 low_sample floor")
        self.assertEqual([5, 16, 20, 20, 20, 20], [int(fn(l)) for l in (1, 4, 8, 16, 32, 64)],
                         "max(MIN_DATA=5, min(20, 4*level)) per level")

    def test_low_sample_cannot_fire_at_c1(self):
        """A consequence worth stating: at c1 the floor collapses onto MIN_DATA, so a c1 stage
        is either `no_data` or clean. v1.1's token clause is what used to flag it, and 160 of
        its 181 flagged bundles offended only at c1."""
        self.assertEqual("ok", str(self.one(1, successful=5, tps=20.0).validity))
        self.assertEqual("ok", str(self.one(1, successful=6, tps=20.0).validity))

    def test_a_tiny_token_budget_alone_is_not_low_sample(self):
        """20 requests × 3 output tokens = 60 tokens, 34x under the withdrawn 2048 budget —
        and 20 requests clears the c16 floor, so the row is clean."""
        v = self.one(16, successful=20, tps=200.0, out_tokens=3.0)
        self.assertEqual("ok", str(v.validity),
                         f"the token budget is not a rule any more (A1); got {v}")

    def test_a_huge_token_budget_does_not_rescue_a_thin_level(self):
        """3 coder requests × 1242 tokens = 3726 tokens, comfortably over the withdrawn budget.
        A1: 'the clause did not merely fail to detect starvation, it approved it.'"""
        v = self.one(32, successful=3, tps=256.19, out_tokens=1242.33)
        self.assertIn("no_data", v.tokens, f"3 < MIN_DATA(5); got {v}")
        self.assertEqual("void", v.status, f"got {v}")

    def test_a_starved_coder_level_is_still_caught(self):
        """The 15 starved levels A1 talks about: 10 requests at c16 clears 2048 tokens easily
        but is under the 20-request floor."""
        v = self.one(16, successful=10, tps=100.0, out_tokens=1005.95)
        self.assertIn("low_sample", v.tokens, f"10 < 20 at c16; got {v}")
        self.assertEqual("suspect", v.status, f"got {v}")

    def test_min_tokens_env_knob_no_longer_changes_any_verdict(self):
        """The sharpest form of the amendment: if a token budget still existed anywhere, an
        absurd `AHL_MIN_TOKENS` would flag a healthy real run. It must not."""
        mod = api.require_validity(self, {"AHL_MIN_TOKENS": "1000000000"})
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "a1")
        v = api.assess(self, mod, b, [1, 16], node_profile=GB10)
        self.assertEqual("ok", str(v.validity),
                         f"AHL_MIN_TOKENS must be inert after A1; got {v}")


# ─────────────────────────────────────────────────────────────────────────────────────────────
# A2 — survivorship is REDEFINED (and then re-adjudicated on measurement)
# ─────────────────────────────────────────────────────────────────────────────────────────────
class TestA2Survivorship(V12TestCase):
    """A2, as finally adjudicated: `survivorship <=> ok > 0 and incomplete > ok`.

    MAJORITY DISCARD — more requests were thrown away than were counted, so the published mean
    is an average over a minority of the work. Two earlier forms were tried and measured out:

      * v1.1 `incomplete >= ok` — arithmetically `ok <= level` (the in-flight set at stage end
        is ~level), so it could not fire below a 50% discard rate while its own justification
        cited 32.4% / 46.2%.
      * v1.2 A2 as written, `incomplete > level AND discard > 30%` — GuideLLM BOUNDS in-flight
        by the concurrency level, so the first clause is unsatisfiable: it fired ZERO times on
        690 levels. (Confirmed independently against this node's bundles while writing these
        tests.) The 30% clause alone flags 19 of 23 coder rows, which is a statement about the
        METHOD, not a per-row defect signal.

    So the rule's LIMIT is part of the spec and is asserted here too: it deliberately does not
    catch the systemic 30-48% coder discard. A test suite that quietly asserted the wider form
    would push the implementation back into flag fatigue.
    """

    def survivorship(self, level, ok, incomplete, **kw):
        return self.one(level, successful=ok, incomplete=incomplete, tps=100.0, **kw)

    def test_majority_discard_fires(self):
        v = self.survivorship(16, 20, 21)          # 21 discarded vs 20 counted
        self.assertIn("survivorship", v.tokens, f"got {v}")
        self.assertIn("survivorship@c16", v.tagged, f"§3 tags it with its level; got {v.tagged}")
        self.assertEqual("suspect", v.status, f"survivorship is suspect-severity; got {v}")

    def test_the_boundary_is_strictly_greater(self):
        """`incomplete == ok` is exactly half discarded and must NOT fire; one more must.

        This pair is the whole rule. A test that only asserted the firing side would pass
        against `incomplete >= ok` — the v1.1 form this replaced.
        """
        equal = self.survivorship(16, 20, 20)
        self.assertNotIn("survivorship", equal.tokens,
                         f"half is not a majority; got {equal}")
        one_more = self.survivorship(16, 20, 21)
        self.assertIn("survivorship", one_more.tokens, f"got {one_more}")

    def test_an_empty_level_does_not_fire(self):
        """'Never fires on an empty level.' With `ok == 0` any positive `incomplete` is
        trivially a majority, and the level is already `no_data` — a second token would only
        add noise to the row that needs it least."""
        v = self.survivorship(16, 0, 16)
        self.assertNotIn("survivorship", v.tokens, f"got {v}")
        self.assertIn("no_data", v.tokens, f"an empty level is no_data; got {v}")

    def test_the_steady_state_in_flight_set_does_not_fire(self):
        """What every healthy level looks like: ~`level` requests still in flight at stage end.
        15 incomplete against 30 completions is a 33% discard and must stay unflagged."""
        v = self.survivorship(16, 30, 15)
        self.assertNotIn("survivorship", v.tokens, f"got {v}")

    def test_the_withdrawn_a2_as_written_form_does_not_fire(self):
        """`incomplete > level AND discard > 30%`: 60 > 16 and 60/160 = 37.5%. The published
        contract text would fire here; the adjudicated rule does not, because 60 discarded
        against 100 counted is not a majority."""
        v = self.survivorship(16, 100, 60)
        self.assertNotIn("survivorship", v.tokens, f"got {v}")

    def test_the_retired_discard_tolerance_knob_is_inert(self):
        """`AHL_DISCARD_TOL` survives for reporting only. If the discard-FRACTION form were
        ever live again, a 10% tolerance would light up an ordinary coder sweep (c32 discards
        24% of its requests) — which is precisely the flag fatigue that got it retired."""
        mod = api.require_validity(self, {"AHL_DISCARD_TOL": "0.10"})
        b = api.copy_fixture_bundle("real_healthy_coder", self.tmp / "tol")
        v = api.assess(self, mod, b, [1, 4, 8, 16, 32], node_profile=GB10)
        self.assertNotIn("survivorship", v.tokens,
                         f"the discard-fraction rule is retired, not merely defaulted; got {v}")

    def test_no_real_bundle_on_this_node_is_flagged(self):
        """The false-positive guard on real evidence: none of the committed healthy fixtures —
        chat, coder, full sweep, llama.cpp, ds4 — may be flagged."""
        for name, levels in (("real_healthy_chat", [1, 16]),
                             ("real_healthy_coder", [1, 4, 8, 16, 32]),
                             ("real_healthy_sweep", [1, 4, 8, 16, 32]),
                             ("real_healthy_llamacpp", [1, 4, 8, 16]),
                             ("real_healthy_ds4", [1])):
            with self.subTest(bundle=name):
                b = api.copy_fixture_bundle(name, self.tmp / ("s_" + name))
                v = api.assess(self, self.mod, b, levels, node_profile=GB10)
                self.assertNotIn("survivorship", v.tokens, f"{name}: {v}")

    def test_the_two_request_c32_defect_is_still_caught_somewhere(self):
        """The real §0 (a) row discards 31 of 33 — a majority — so survivorship fires there as
        well as `no_data`. Kept as a check that narrowing the rule did not narrow it past the
        defect it was introduced for."""
        b = api.copy_fixture_bundle("real_thin_coder", self.tmp / "thin")
        v = api.assess(self, self.mod, b, [1, 32], node_profile=GB10)
        self.assertIn("survivorship@c32", v.tagged, f"got {v.tagged}")
        self.assertEqual("void", v.status, f"got {v}")



# ─────────────────────────────────────────────────────────────────────────────────────────────
# A3 — new fatal verdict `no_output`
# ─────────────────────────────────────────────────────────────────────────────────────────────
class TestA3NoOutput(V12TestCase):
    """A3: '`successful > 0` but `tps` is null, non-finite, or `<= 0` -> **fatal**.'

    'There is currently a ceiling on throughput and no floor: a serve emitting zero output
    tokens returns `validity=ok` (verified with 200 successful requests at 0.0 tok/s).
    AGENTS.md records NemotronH doing exactly this under think-off, so it is not hypothetical.'
    """

    def test_zero_throughput_with_successful_requests_is_fatal(self):
        v = self.one(16, successful=200, tps=0.0, out_tokens=0.0)
        self.assertIn("no_output", v.tokens,
                      f"200 successful requests at 0.0 tok/s is not a measurement; got {v}")
        self.assertEqual("void", v.status, f"A3 makes it fatal; got {v}")
        self.assertIn("no_output@c16", v.tagged, f"got {v.tagged}")

    def test_negative_throughput_is_fatal(self):
        v = self.one(16, successful=200, tps=-1.0)
        self.assertIn("no_output", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")

    def test_a_missing_throughput_metric_is_fatal(self):
        """`tps` is null: the metric block is absent from an otherwise well-formed bundle."""
        doc = api.level_json(200, 0, 0, 100.0, rate=16)
        del doc["benchmarks"][0]["metrics"]["output_tokens_per_second"]
        v = self.raw(16, doc)
        self.assertIn("no_output", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")

    def test_a_nan_throughput_is_fatal(self):
        """Non-finite. `NaN` is a real thing json.load accepts, and a NaN mean is precisely how
        a broken metric reaches the journal as a number-shaped value."""
        doc = api.level_json(200, 0, 0, 100.0, rate=16)
        doc["benchmarks"][0]["metrics"]["output_tokens_per_second"]["successful"]["mean"] = \
            float("nan")
        self.n += 1
        p = self.tmp / f"nan{self.n}"
        p.mkdir(parents=True, exist_ok=True)
        (p / "level_c16.json").write_text(json.dumps(doc))    # json.dumps emits a bare NaN
        v = api.assess(self, self.mod, p, [16], node_profile=NO_BW)
        self.assertIn("no_output", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")

    def test_a_healthy_level_is_not_no_output(self):
        v = self.one(16, successful=200, tps=161.55)
        self.assertNotIn("no_output", v.tokens, f"got {v}")
        self.assertEqual("ok", str(v.validity), f"got {v}")

    def test_no_output_needs_successful_requests(self):
        """'`successful > 0` but ...' — an empty level is `no_data`; the two must not double up
        or the verdict string stops naming the actual failure."""
        v = self.one(16, successful=0, incomplete=16, tps=0.0)
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertNotIn("no_output", v.tokens,
                         f"no successful requests -> no_data, not no_output; got {v}")

    def test_every_healthy_fixture_stays_clear_of_it(self):
        for name, levels in (("real_healthy_chat", [1, 16]),
                             ("real_healthy_coder", [1, 4, 8, 16, 32]),
                             ("real_healthy_llamacpp", [1, 4, 8, 16])):
            with self.subTest(bundle=name):
                b = api.copy_fixture_bundle(name, self.tmp / ("n_" + name))
                v = api.assess(self, self.mod, b, levels, node_profile=GB10)
                self.assertNotIn("no_output", v.tokens, f"{name}: {v}")


# ─────────────────────────────────────────────────────────────────────────────────────────────
# A4 — `errored` escalates
# ─────────────────────────────────────────────────────────────────────────────────────────────
class TestA4ErroredEscalates(V12TestCase):
    """A4: '`errored/(successful+errored) > 0.50` -> **fatal**.'

    'A level with 107,589 errors and 17 successes — a dead endpoint — carried the same severity
    as one with 11% errors ... it is what catches a dead endpoint whose reported tok/s happens
    to land under the roofline.'

    The fatal band is a DISTINCT BASE TOKEN, `errored_fatal`, not `errored` at a different
    severity: `validity` is the only thing a consumer reading a committed row has, so severity
    has to be legible from the string alone. The two bands are therefore mutually exclusive,
    and that is asserted, because a rule that emitted both would make `errored` mean two things.

    The roofline is disabled throughout (no `gpu.mem_bw_gbs`) so the escalation is the only
    thing that can produce `void`.
    """

    def errored(self, ok, err):
        return self.one(16, successful=ok, errored=err, tps=200.0)

    def test_eleven_percent_is_suspect_not_fatal(self):
        v = self.errored(899, 101)                 # 10.1%
        self.assertIn("errored", v.tokens, f"got {v}")
        self.assertNotIn("errored_fatal", v.tokens, f"got {v}")
        self.assertEqual("suspect", v.status, f"under 50% stays suspect; got {v}")

    def test_exactly_fifty_percent_is_not_fatal(self):
        v = self.errored(500, 500)                 # 0.50, not > 0.50
        self.assertIn("errored", v.tokens, f"got {v}")
        self.assertNotIn("errored_fatal", v.tokens, f"the rule is strictly `>`; got {v}")
        self.assertEqual("suspect", v.status, f"got {v}")

    def test_just_over_fifty_percent_is_fatal(self):
        v = self.errored(499, 501)                 # 0.501
        self.assertIn("errored_fatal", v.tokens, f"got {v}")
        self.assertNotIn("errored", v.tokens,
                         f"the two bands are mutually exclusive; got {v}")
        self.assertEqual("void", v.status, f"over half the requests failed; got {v}")
        self.assertIn("errored_fatal@c16", v.tagged, f"got {v.tagged}")

    def test_the_severity_is_legible_from_the_persisted_token_alone(self):
        """The reason for a separate base name: a consumer reading `validity` out of a
        committed results.tsv row has no access to the bundle that produced it."""
        floor = api.attr(self, self.mod, "status_floor", what="the §5 status floor")
        self.assertEqual("void", floor(["errored_fatal@c16"]), "fatal band")
        self.assertEqual("suspect", floor(["errored@c16"]), "suspect band")

    def test_the_real_dead_endpoint_is_fatal_on_the_error_rate_alone(self):
        """The sibling row A4 names: ok=16 against errored=112069, judged with the roofline
        check switched OFF (no `gpu.mem_bw_gbs`). Under v1.1 this graded `suspect`."""
        b = api.copy_fixture_bundle("real_dead_endpoint", self.tmp / "dead")
        (b / "level_c1.json").unlink()
        v = api.assess(self, self.mod, b, [16], node_profile=NO_BW)
        self.assertIn("errored_fatal", v.tokens, f"got {v}")
        self.assertEqual("void", v.status,
                         f"99.99% errored is not data, roofline or no roofline; got {v}")

    def test_a_clean_level_is_not_errored(self):
        v = self.errored(1000, 0)
        self.assertEqual("ok", str(v.validity), f"got {v}")

    def test_the_fatal_tolerance_is_env_overridable(self):
        mod = api.require_validity(self, {"AHL_ERR_FATAL": "0.05"})
        b = api.write_bundle(self.tmp / "errtol",
                             {16: api.level_json(899, 101, 0, 200.0, rate=16)})
        v = api.assess(self, mod, b, [16], node_profile=NO_BW)
        self.assertIn("errored_fatal", v.tokens,
                      f"10.1% > the overridden 5% fatal band; got {v}")


# ─────────────────────────────────────────────────────────────────────────────────────────────
# A5 — `na` is never `ok`, in the library too
# ─────────────────────────────────────────────────────────────────────────────────────────────
class TestA5NaIsNeverOk(V12TestCase):
    """A5: '`parse_validity("na")` returned `["ok"]` and `verdicts({})` returned `["ok"]`. §3
    has said since v1.1 that `na` means "could not be evaluated — never `ok`"; the library
    asserted the opposite, so any consumer that parsed before checking was wrong by
    construction. An empty or unreadable bundle now yields `na` with a **suspect** floor.'
    """

    def test_parse_validity_does_not_turn_na_into_ok(self):
        parse = api.attr(self, self.mod, "parse_validity", what="the §2 validity decoding")
        self.assertNotEqual(["ok"], list(parse("na")),
                            "`na` is not `ok` — that equality is the defect A5 names")
        self.assertIn("na", list(parse("na")), "`na` reports itself")

    def test_no_evidence_at_all_is_na(self):
        verdicts = api.attr(self, self.mod, "verdicts", what="the §3 verdict computation")
        out = list(verdicts({}))
        self.assertNotEqual(["ok"], out, f"nothing was evaluated; got {out}")
        self.assertIn("na", out, f"got {out}")

    def test_the_na_floor_is_suspect(self):
        floor = api.attr(self, self.mod, "status_floor", what="the §5 status floor")
        self.assertEqual("suspect", floor(["na"]),
                         "an unevaluable row is not citable, but it is not disproven either")

    def test_assess_of_a_bundleless_row_is_na_and_suspect(self):
        b = self.tmp / "no_bundle_at_all"
        b.mkdir()
        v = api.assess(self, self.mod, b, [], node_profile=GB10)
        self.assertEqual("na", str(v.validity), f"got {v}")
        self.assertEqual("suspect", v.status, f"got {v}")
        self.assertEqual("na", str(v.req_counts), f"§2: `na` when the row has no bundle; {v}")

    def test_a_retained_but_empty_bundle_is_stricter_than_na(self):
        """§2, and the reason §7 counts 1 `na` row and not 6: 'A bundle directory that survives
        but retains no `level_c*.json` is NOT the same case: those rows render `c1:na` and score
        `no_data`, which is fatal and therefore stricter than `na`.'"""
        b = self.tmp / "empty_retained"
        b.mkdir()
        v = api.assess(self, self.mod, b, [1, 16], node_profile=GB10)
        self.assertIn("no_data", v.tokens, f"got {v}")
        self.assertEqual("void", v.status, f"got {v}")
        self.assertEqual("c1:na;c16:na", str(v.req_counts), f"got {v}")


# ─────────────────────────────────────────────────────────────────────────────────────────────
# A10 — the tested path must be the executed path
# ─────────────────────────────────────────────────────────────────────────────────────────────
class TestA10CliAgreesWithTheLibrary(V12TestCase):
    """A10: '`assess_bundle(discover=False)` vs the CLI's `discover=True` gave **opposite
    verdicts on the same evidence**, and the code comment stated the inverse of what the code
    did. The tested path must be the executed path: the caller's run-level list is authoritative
    everywhere.'

    bench.sh reaches the rules through the CLI (via `validity.sh`); this suite reaches them
    through `assess_bundle`. If those two disagree, the suite is testing something the lab never
    runs — which is how the bug got in.
    """

    def both(self, bundle, levels, cells):
        lib = api.assess(self, self.mod, bundle, levels, node_profile=GB10,
                         tps={lv: c for lv, c in zip(api.ALL_LEVELS, cells.split(","))})
        cli = api.cli_check(self, bundle, levels, tps=cells, node_profile=GB10)
        return lib, cli

    def assertAgree(self, lib, cli):
        self.assertEqual(str(lib.validity), cli["validity"],
                         f"CLI and assess_bundle disagree: {lib} vs {cli}")
        self.assertEqual(str(lib.req_counts), cli["req_counts"], f"{lib} vs {cli}")

    def test_healthy_real_bundle(self):
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "h")
        self.assertAgree(*self.both(b, [1, 16], "18.68,na,na,161.55,na"))

    def test_thin_real_bundle(self):
        b = api.copy_fixture_bundle("real_thin_coder", self.tmp / "t")
        lib, cli = self.both(b, [1, 32], "24.06,na,na,na,256.19")
        self.assertAgree(lib, cli)
        self.assertEqual("void", cli["status_floor"], f"got {cli}")

    def test_a_stale_level_file_is_ignored_by_both(self):
        """The exact divergence A10 names: a `level_c8.json` left behind by a previous shape.
        The run-level list is authoritative, so NEITHER path may score it."""
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "stale")
        (b / "level_c8.json").write_text(
            json.dumps(api.level_json(2, 0, 40, 999.0, rate=8)))   # a starved leftover
        lib, cli = self.both(b, [1, 16], "18.68,na,na,161.55,na")
        self.assertAgree(lib, cli)
        self.assertEqual("ok", cli["validity"],
                         f"a stale file from another shape is not evidence; got {cli}")

    def test_a_hung_level_agrees_on_both_paths(self):
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "hang")
        (b / "level_c16.json").unlink()
        lib, cli = self.both(b, [1, 16], "18.68,na,na,hang,na")
        self.assertAgree(lib, cli)
        self.assertIn("no_data@c16", cli["validity"], f"got {cli}")

    def test_an_unrun_level_agrees_on_both_paths(self):
        b = api.copy_fixture_bundle("real_healthy_chat", self.tmp / "unrun")
        (b / "level_c16.json").unlink()
        lib, cli = self.both(b, [1], "18.68,na,na,na,na")
        self.assertAgree(lib, cli)
        self.assertEqual("ok", cli["validity"], f"got {cli}")


if __name__ == "__main__":
    unittest.main()
