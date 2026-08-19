"""Structural checks on §1 (single source of truth) and §5 (enforcement wiring).

These are static reads of the scripts, never executions: `bench.sh` needs docker, a live vLLM
endpoint and the GPU, and this box is a shared single-GPU lab that may be serving right now
(contract §8). Static is the only honest way to assert this wiring from a test — the checks are
deliberately shallow, and say so, rather than pretending to be end-to-end.
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


def source(rel: str) -> str | None:
    p = api.REPO_ROOT / rel
    return p.read_text().replace("\\t", "\t") if p.exists() else None


class TestHeaderExistsOnce(unittest.TestCase):
    """§1: 'Four files currently hard-code the header string ... after this work the header
    exists once, in the library, and is consumed from there.'"""

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

    def test_the_shell_shim_does_not_reimplement_a_rule(self):
        """§1: 'a thin bash shim ... it must not re-implement any rule.' A shim that carries its
        own thresholds is the exact failure this contract is trying to prevent."""
        if not api.VALIDITY_SH.exists():
            self.skipTest("scripts/lib/validity.sh not implemented yet (A1 owns it)")
        src = api.VALIDITY_SH.read_text()
        code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
        self.assertRegex(code, r"validity\.py|python",
                         "the shim must delegate to scripts/lib/validity.py")
        for pattern, rule in ((r"-lt\s+5\b|<\s*5\b", "MIN_DATA"),
                              (r"-lt\s+20\b|<\s*20\b", "MIN_SUCCESSFUL")):
            self.assertNotRegex(code, pattern,
                                f"validity.sh appears to re-implement the {rule} rule (§1)")


class TestBenchWiring(unittest.TestCase):
    """§5: bench.sh records, flags, and exits 4."""

    def setUp(self):
        api.require_validity(self)
        self.src = source("scripts/bench.sh")
        if self.src is None:
            self.skipTest("scripts/bench.sh missing")
        if "validity" not in self.src:
            self.skipTest("scripts/bench.sh not wired to the validity layer yet (A2 owns it)")

    def test_bench_consumes_the_library(self):
        self.assertRegex(self.src, r"lib/validity\.(sh|py)",
                         "bench.sh must consume scripts/lib/validity.{sh,py}, not its own copy")

    def test_bench_has_a_validity_exit_path_of_4(self):
        self.assertRegex(
            self.src, r"exit[^\n]*\b4\b|EXIT_INVALID|EXIT_VALIDITY|VALIDITY_EXIT",
            "§5 pins the validity failure exit code at 4, distinct from 3 = crash/hang")

    def test_bench_keeps_the_crash_exit_path_of_3(self):
        self.assertRegex(self.src, r"(exit|return|rc_all=)\s*=?\s*3\b",
                         "the crash exit code 3 must survive the rewrite (§5)")

    def test_the_failing_row_is_still_written(self):
        """§5: 'A failing run is still written to results.tsv — the evidence must survive in the
        committed journal, not only in the gitignored bundle.'"""
        self.assertIn("emit_row", self.src, "bench.sh no longer emits a row")

    def test_bench_records_the_knobs_it_actually_used(self):
        """§2 rationale: a MAX_SECONDS=600 baseline and a 180 finalize were indistinguishable."""
        self.assertRegex(self.src, r"knobs", "bench.sh must populate the `knobs` column")


class TestDownstreamConsumers(unittest.TestCase):
    """§5: 'Downstream consumers must treat void as non-existent data and suspect as
    non-citable.' Three separate promises, three separate tests."""

    def setUp(self):
        api.require_validity(self)

    def _needs(self, rel, *words):
        src = source(rel)
        if src is None:
            self.skipTest(f"{rel} missing")
        if not any(w in src for w in ("validity", "suspect", "void")):
            self.skipTest(f"{rel} not wired to the validity layer yet")
        for w in words:
            self.assertIn(w, src, f"{rel} must know about {w!r} (§5)")

    def test_promote_refuses_void_and_suspect(self):
        self._needs("scripts/promote.sh", "void", "suspect")

    def test_run_experiment_refuses_to_median_over_them(self):
        self._needs("scripts/run_experiment.sh", "void", "suspect")

    def test_aggregate_filters_them_from_the_default_view(self):
        self._needs("scripts/aggregate.py", "void", "suspect")


class TestProbeRecordsBandwidth(unittest.TestCase):
    """§4: 'mem_bw_GB_s comes from node_profile.json -> gpu.mem_bw_gbs (new field; the probe
    must record it — 273 for GB10/LPDDR5X).'"""

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


if __name__ == "__main__":
    unittest.main()
