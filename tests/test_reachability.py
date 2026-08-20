"""`scripts/citability_selftest.sh` — folded into the acceptance suite.

That script (68 checks) already does for `promote.sh`, `run_experiment.sh`,
`run_experiment_llamacpp.sh`, `suite.sh` and `validate.sh` exactly what this suite now does for
`bench.sh` and `aggregate.py`: it runs the REAL script inside a throwaway repo whose children are
stubs returning scripted exit codes, and asserts on which branch actually executed.

It was not part of `tests/run.sh`, which is why four of the sixteen surviving mutations —
"`promote.sh` stops blocking non-citable rows", "`suite.sh` maps bench exit 4 to ok", and the two
runner guards — could be applied with the suite still green. A reachability harness that nothing
runs is not a gate. One test module, so `tests/run.sh` is the single entry point again.

It is hermetic on the same terms as the rest of the suite: no docker, no server, no
guidellm/lm-eval, no GPU (it exports `AHL_PYTHON=python3` to keep even `uv` out of it), and it
takes a few seconds.
"""
from __future__ import annotations

import re
import subprocess
import sys
import unittest

from ahl_test import api

SELFTEST = api.REPO_ROOT / "scripts" / "citability_selftest.sh"


class TestCitabilityReachability(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proc = None
        if SELFTEST.exists():
            cls.proc = subprocess.run(["bash", str(SELFTEST), "-v"], cwd=str(api.REPO_ROOT),
                                      capture_output=True, text=True, timeout=300)

    def setUp(self):
        if self.proc is None:
            self.skipTest(f"not implemented yet: {SELFTEST.relative_to(api.REPO_ROOT)} "
                          "— the consumer reachability harness")

    def tail(self) -> str:
        return (self.proc.stdout or "")[-4000:] + "\n--- stderr ---\n" + \
               (self.proc.stderr or "")[-2000:]

    def test_every_consumer_reachability_check_passes(self):
        self.assertEqual(0, self.proc.returncode,
                         "a consumer gate is unreachable or answers wrongly\n" + self.tail())
        failures = [l for l in self.proc.stdout.splitlines()
                    if l.lstrip().startswith("FAIL ")]
        self.assertEqual([], failures, self.tail())

    def test_it_actually_ran_the_checks(self):
        """A harness that silently executed nothing would report 0 failures too. The summary
        line is the count, and it must not have shrunk."""
        m = re.search(r"citability_selftest: (\d+) passed, (\d+) failed", self.proc.stdout)
        self.assertIsNotNone(m, "no summary line — did the harness run?\n" + self.tail())
        passed, failed = int(m.group(1)), int(m.group(2))
        self.assertEqual(0, failed, self.tail())
        self.assertGreaterEqual(passed, 60,
                                f"only {passed} checks ran; the harness has lost coverage")

    def test_it_covers_every_consumer_named_in_the_contract(self):
        """§5 names four consumers of the verdict. Each must appear as an executed section, so
        deleting one section is visible here rather than silently reducing the gate."""
        for consumer in ("promote.sh", "run_experiment.sh", "suite.sh", "validate.sh"):
            with self.subTest(consumer=consumer):
                self.assertIn(consumer, self.proc.stdout,
                              f"{consumer} is no longer exercised\n" + self.tail())

    def test_it_stays_hermetic(self):
        """Contract §8. The harness may mention docker in a comment; it may not invoke it."""
        code = "\n".join(l for l in SELFTEST.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        for banned in ("docker ", "nvidia-smi", "guidellm ", "lm_eval", "lm-eval"):
            with self.subTest(banned=banned.strip()):
                self.assertNotIn(banned, code,
                                 f"the reachability harness must not invoke {banned.strip()}")


if __name__ == "__main__":
    unittest.main()
