#!/usr/bin/env bash
# tests/run.sh — the acceptance suite for the measurement-validity layer (docs/validity-contract.md).
#
#   tests/run.sh                              # everything
#   tests/run.sh test_roofline test_status    # only these modules
#   tests/run.sh -q                           # quiet
#   AHL_TEST_STRICT=1 tests/run.sh            # a SKIP fails the run (use this post-merge)
#
# Hermetic by construction: stdlib `unittest` only, no network, no server, no accelerator, no
# container runtime. Zero test dependencies (charter rule 4: bash, or python via uv/uvx).
# Whole suite runs in a couple of seconds.
#
# GREEN-ON-SKIP. The implementation under test is written by sibling agents
# (scripts/lib/validity.py, scripts/lib/validity.sh, scripts/migrate_results_tsv.py). Until it
# merges, every test that targets it SKIPS with a message naming exactly what is missing, and
# this script exits 0. After the merge the same suite is the acceptance gate — run it with
# AHL_TEST_STRICT=1, because a skip means "this contract rule was not checked", not "it passed".
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSITY=(-v); ARGS=()
for a in "$@"; do
  case "$a" in
    -q|--quiet)   VERBOSITY=() ;;
    -v|--verbose) VERBOSITY=(-v) ;;
    *)            ARGS+=("$a") ;;
  esac
done

# Charter rule 4: python via uv. `--no-project --offline` keeps it off the network and away from
# the heavy project dependencies — this suite imports nothing outside the standard library.
if command -v uv >/dev/null 2>&1; then
  PY=(uv run --no-project --offline python)
else
  PY=(python3)
  echo "note: uv not on PATH, falling back to python3" >&2
fi

LOG="$(mktemp -t ahl-tests.XXXXXX)"
trap 'rm -f "$LOG"' EXIT
cd "$TESTS_DIR"
set +e
if [ "${#ARGS[@]}" -gt 0 ]; then
  "${PY[@]}" -m unittest "${VERBOSITY[@]}" "${ARGS[@]}" 2>&1 | tee "$LOG"
else
  "${PY[@]}" -m unittest discover "${VERBOSITY[@]}" -s . -t . -p 'test_*.py' 2>&1 | tee "$LOG"
fi
rc="${PIPESTATUS[0]}"
set -e

if [ "$rc" -eq 0 ] && [ "${AHL_TEST_STRICT:-0}" = 1 ] && grep -q 'skipped=' "$LOG"; then
  echo >&2
  echo "AHL_TEST_STRICT=1: a skipped test is an UNCHECKED contract rule, not a pass." >&2
  grep -E "skipped '" "$LOG" | sed 's/^/  /' >&2 || true
  exit 1
fi
exit "$rc"
