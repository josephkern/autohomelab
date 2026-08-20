"""Structural LINTS on §1, plus the suite's own hygiene rules.

**What this module is not.** It used to be where the §5 enforcement wiring was "asserted", by
grepping the scripts for substrings. Every one of those assertions was satisfiable by a comment:

    assertRegex(src, r"knobs")                      # passes on the word `knobs` in a docstring
    _needs("scripts/promote.sh", "void", "suspect") # passes on "# void and suspect are unhandled"

and nothing checked that `bench.sh` passed `--node-profile`, so the entire §4 roofline check sat
dead on the primary bencher while the suite reported 121/121 green (contract v1.2 A6/A8). Those
tests are gone. The wiring is now asserted by EXECUTING it:

    test_bench_enforcement.py   bench.sh — status downgrade, exit 3/4, --node-profile, fail-closed
    test_consumers.py           aggregate.py's default view; the header's single definition
    test_reachability.py        promote.sh / suite.sh / validate.sh / run_experiment*.sh

What remains here is what a lint can honestly answer: does a second copy of the schema literal
exist anywhere, and does the suite itself obey the charter.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

from ahl_test import api

# `\t` inside a bash $'...' header is a backslash + a word character, so normalize the escape
# before matching or the bench*.sh literals slip through.
HEADER_LITERAL = re.compile(r"run_id\W{1,6}commit\W{1,6}node_fp")
BENCH_SCRIPTS = ["scripts/bench.sh", "scripts/bench_ds4.sh", "scripts/bench_llamacpp.sh"]
HEADER_CONSUMERS = BENCH_SCRIPTS + ["scripts/aggregate.py"]


def source(rel: str):
    p = api.REPO_ROOT / rel
    return p.read_text().replace("\\t", "\t") if p.exists() else None


class TestNoSecondCopyOfTheSchema(unittest.TestCase):
    """§1: 'The header string previously existed in four hard-coded copies ... all four now
    consume it from the library.'

    A lint, deliberately: `test_consumers.py` proves the consumers *read* the library by moving
    the library and watching them follow. This catches the other half — a stale duplicate left
    lying around that nothing reads yet, which is how the four copies drifted apart in the first
    place (the schema went 16 -> 20 columns and only the documentation disagreed).
    """

    def setUp(self):
        api.require_validity(self)

    def test_no_caller_hard_codes_the_column_list(self):
        for rel in HEADER_CONSUMERS:
            src = source(rel)
            if src is None:
                continue
            with self.subTest(script=rel):
                m = HEADER_LITERAL.search(src)
                msg = "" if m is None else (
                    f"{rel} still hard-codes the schema: {src[m.start():m.start() + 90]!r}")
                self.assertIsNone(m, msg)

    def test_the_library_holds_it_instead(self):
        self.assertRegex(api.VALIDITY_PY.read_text().replace("\\t", "\t"), HEADER_LITERAL,
                         "scripts/lib/validity.py must be where the schema lives (§1)")

    def test_the_shim_delegates_to_the_library(self):
        if not api.VALIDITY_SH.exists():
            self.skipTest("scripts/lib/validity.sh not implemented yet (F3 owns it)")
        code = "\n".join(l for l in api.VALIDITY_SH.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        self.assertRegex(code, r"validity\.py|python",
                         "the shim must delegate to scripts/lib/validity.py")


class TestProbeRecordsBandwidth(unittest.TestCase):
    """§4: '`mem_bw_GB_s` <- `node_profile.json` -> `gpu.mem_bw_gbs`.'

    A lint too, and the only one left that cannot be executed: `probe.sh` reads the GPU, and no
    test on this box may (contract §8). The behaviour that matters — an absent figure SKIPS the
    check rather than guessing one — is executed in test_roofline.py and
    test_bench_enforcement.py against both node-profile fixtures.
    """

    def test_probe_emits_mem_bw_gbs(self):
        src = source("scripts/probe.sh")
        if src is None:
            self.skipTest("scripts/probe.sh missing")
        if "mem_bw" not in src:
            self.skipTest("probe.sh does not record gpu.mem_bw_gbs yet — §4 requires it")
        self.assertIn("mem_bw_gbs", src)


class TestCharterCompliance(unittest.TestCase):
    """§8 / charter rule 4 — applies to the new files as much as the old ones."""

    def test_new_shell_scripts_set_euo_pipefail(self):
        for p in [api.VALIDITY_SH, api.TESTS_DIR / "run.sh",
                  api.TESTS_DIR / "mutate.sh",
                  api.TESTS_DIR / "tools" / "minimize_bundle.sh"]:
            if not p.exists():
                continue
            with self.subTest(script=p.name):
                self.assertIn("set -euo pipefail", p.read_text())

    def test_no_new_language_snuck_in(self):
        allowed = {".sh", ".py", ".md", ".json", ".tsv"}
        offenders = sorted(str(p.relative_to(api.TESTS_DIR))
                           for p in api.TESTS_DIR.rglob("*")
                           if p.is_file() and p.suffix not in allowed
                           and "__pycache__" not in p.parts)
        self.assertEqual([], offenders, "charter rule 4: bash or python via uv/uvx only")

    def test_the_suite_never_reaches_into_the_gitignored_bundles(self):
        """Hermetic by construction: fixtures are committed, `results/**/data/` is not, and a
        test that read the live results tree would pass or fail based on lab activity.

        This file is excluded from its own scan: it necessarily spells the forbidden strings.
        """
        needles = ('REPO_ROOT / "results"', "REPO_ROOT/'results'", "dgx-homelab/results")
        for p in sorted(api.TESTS_DIR.rglob("*.py")):
            if p.name == Path(__file__).name or "__pycache__" in p.parts:
                continue
            body = p.read_text()
            with self.subTest(file=p.name):
                for n in needles:
                    self.assertNotIn(n, body, f"{p.name} reaches outside tests/fixtures")

    def test_the_entry_point_never_touches_docker_or_the_gpu(self):
        """Contract §8 / the standing lab rule: no agent runs docker, serves a model, or touches
        the GPU. `tests/run.sh` is what a human or the orchestrator actually executes."""
        run = api.TESTS_DIR / "run.sh"
        if not run.exists():
            self.skipTest("tests/run.sh missing")
        body = "\n".join(l for l in run.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        for banned in ("docker", "nvidia-smi", "vllm", "curl", "wget"):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, body,
                                 f"tests/run.sh must stay offline and hardware-free ({banned})")

    def test_the_stubs_the_wiring_tests_install_can_never_be_the_real_thing(self):
        """The executing wiring tests put `docker`, `uv` and an adapter on PATH. If one of those
        stubs ever fell through to the real binary, a test run would touch the lab's single
        shared GPU. Assert the stub sources contain no path to a real one."""
        scratch = api.TESTS_DIR / "ahl_test" / "scratch.py"
        if not scratch.exists():
            self.skipTest("tests/ahl_test/scratch.py missing")
        body = scratch.read_text()
        for banned in ("/usr/bin/docker", "docker run", "docker exec", "nvidia-smi",
                       "vllm serve", "lm_eval"):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, body,
                                 f"the scratch harness must never reach {banned}")


if __name__ == "__main__":
    unittest.main()
