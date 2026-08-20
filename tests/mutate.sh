#!/usr/bin/env bash
# tests/mutate.sh — the mutation harness for the measurement-validity acceptance suite.
#
#   tests/mutate.sh                       # every mutation, serially
#   tests/mutate.sh survivorship_deleted  # just these
#   tests/mutate.sh -l                    # list them
#   tests/mutate.sh -k                    # keep the scratch copies for inspection
#
# Contract v1.2 A8: "A mutation harness is part of the suite. A rule with no mutation that turns
# the suite red is an untested rule."
#
# WHAT IT DOES
#   For each mutation in tests/tools/mutations.py:
#     1. copy the repo (minus .git, results/, source/, __pycache__) into a scratch directory;
#     2. apply the mutation TO THE COPY — the working tree is never touched;
#     3. run tests/run.sh inside the copy;
#     4. compare the set of failing tests against the unmutated BASELINE run.
#   A mutation that produces no NEW failure is a SURVIVOR: the rule it breaks is not tested.
#
# WHY IT COMPARES FAILURE SETS, NOT EXIT CODES
#   If the baseline is red for an unrelated reason, an exit-code comparison scores every mutation
#   "killed" and reports a clean sheet — a false green of exactly the kind this suite exists to
#   remove. The baseline is run first and its failures are subtracted from every mutant's.
#
# WHY IT IS SERIAL
#   A first attempt at this raced two mutators over one scratch directory and reported everything
#   red, which is the same false-green artifact wearing the opposite colour. One mutation at a
#   time, one directory each. It takes a few minutes; correctness of a correctness-checker is
#   worth a few minutes.
#
# Hermetic on the same terms as the suite it runs: no docker, no server, no guidellm/lm-eval, no
# GPU (contract §8).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CATALOGUE="$TESTS_DIR/tools/mutations.py"
PY="${AHL_PYTHON:-python3}"
KEEP=0
ARGS=()
for a in "$@"; do
  case "$a" in
    -l|--list) "$PY" "$CATALOGUE" list; exit 0 ;;
    -k|--keep) KEEP=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         ARGS+=("$a") ;;
  esac
done

WORK="$(mktemp -d -t ahl-mutate.XXXXXX)"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
[ "$KEEP" = 1 ] && echo "scratch copies kept in $WORK" >&2

# ── one scratch copy of the repo ──────────────────────────────────────────────
# The whole point is that the repo under test is a COPY. results/ is excluded because it is
# gitignored bundle data the suite must never read anyway, and it is gigabytes.
# .venv is excluded because it is ~5 GB and the suite runs `uv run --no-project`, so it is never
# read from the copy. Copying it made a full 38-mutation run hours of pointless I/O, and one run
# aborted mid-table with `tar: ./.venv/… file changed as we read it` while another agent's suite
# was writing there — a silent `set -e` death that looked like a passing table cut short.
# The copy failing is now a hard, reported error rather than a truncated run.
make_copy() {  # make_copy <dest>
  mkdir -p "$1"
  if ! tar -C "$REPO_ROOT" -cf - \
      --exclude=.git --exclude=results --exclude=source --exclude=__pycache__ \
      --exclude=.claude --exclude=.venv --exclude='*.pyc' . | tar -C "$1" -xf - ; then
    echo "!! make_copy FAILED for $1 — the mutation table below is INCOMPLETE, not clean" >&2
    return 1
  fi
}

# ── run the suite in a copy, print its failing-test names, one per line ───────
run_suite() {  # run_suite <repo_copy> <logfile>
  local root="$1" log="$2" rc=0
  ( cd "$root" && AHL_PYTHON="$PY" AHL_TEST_STRICT=0 timeout 900 bash tests/run.sh ) \
      >"$log" 2>&1 || rc=$?
  # Test identities, not counts: `FAIL: name (module.Class.name)` / `ERROR: ...`.
  grep -E '^(FAIL|ERROR): ' "$log" | sed 's/ *$//' | sort -u || true
  return 0
}

# ── baseline ──────────────────────────────────────────────────────────────────
echo "== baseline (unmutated copy) ==" >&2
BASE_DIR="$WORK/_baseline"
make_copy "$BASE_DIR"
BASE_LOG="$WORK/_baseline.log"
run_suite "$BASE_DIR" "$BASE_LOG" > "$WORK/_baseline.fails"
BASE_N="$(wc -l < "$WORK/_baseline.fails")"
BASE_TOTAL="$(grep -oE '^Ran [0-9]+ tests' "$BASE_LOG" | grep -oE '[0-9]+' | head -1 || echo 0)"
if [ "$BASE_TOTAL" = 0 ]; then
  echo "!! the baseline suite ran NO tests — the harness would score every mutation 'killed'." >&2
  sed -n '1,40p' "$BASE_LOG" >&2
  exit 2
fi
echo "   $BASE_TOTAL tests, $BASE_N failing before any mutation" >&2
[ "$BASE_N" -gt 0 ] && sed 's/^/   pre-existing: /' "$WORK/_baseline.fails" >&2

# ── the mutations, ONE AT A TIME ──────────────────────────────────────────────
if [ "${#ARGS[@]}" -gt 0 ]; then
  NAMES=("${ARGS[@]}")
else
  mapfile -t NAMES < <("$PY" "$CATALOGUE" list | cut -f1)
fi

KILLED=0; SURVIVED=0; NA=0; BROKEN=0
SURVIVORS=(); NA_LIST=(); BROKEN_LIST=()
printf '\n%-42s %-14s %s\n' "MUTATION" "RESULT" "NEW FAILURES"
printf '%s\n' "----------------------------------------------------------------------------------"
for name in "${NAMES[@]}"; do
  [ -n "$name" ] || continue
  dir="$WORK/$name"
  make_copy "$dir"
  status="$("$PY" "$CATALOGUE" apply "$name" "$dir")"
  if [ "$status" != applied ]; then
    NA=$((NA + 1)); NA_LIST+=("$name")
    printf '%-42s %-14s %s\n' "$name" "N/A" "pattern not found in $("$PY" "$CATALOGUE" list | grep -P "^$name\t" | cut -f2)"
    rm -rf "$dir"
    continue
  fi
  run_suite "$dir" "$WORK/$name.log" > "$WORK/$name.fails"
  # A mutant whose suite could not RUN (a syntax error, an import failure) proves nothing about
  # the rule — it would otherwise be scored KILLED for the wrong reason, which is the same
  # confusion in miniature that this harness exists to prevent.
  ran="$(grep -oE '^Ran [0-9]+ tests' "$WORK/$name.log" | grep -oE '[0-9]+' | head -1 || echo 0)"
  if [ "${ran:-0}" -lt "$BASE_TOTAL" ]; then
    BROKEN=$((BROKEN + 1)); BROKEN_LIST+=("$name")
    printf '%-42s %-14s %s\n' "$name" "BROKEN" "ran $ran of $BASE_TOTAL tests — mutation is invalid"
    [ "$KEEP" = 1 ] || rm -rf "$dir"
    continue
  fi
  # NEW failures only: anything the baseline already failed proves nothing about this mutation.
  new="$(comm -13 "$WORK/_baseline.fails" "$WORK/$name.fails" | wc -l)"
  if [ "$new" -gt 0 ]; then
    KILLED=$((KILLED + 1))
    first="$(comm -13 "$WORK/_baseline.fails" "$WORK/$name.fails" | head -1 | sed 's/^[A-Z]*: //')"
    printf '%-42s %-14s %s\n' "$name" "KILLED" "$new  (e.g. ${first%% *})"
  else
    SURVIVED=$((SURVIVED + 1)); SURVIVORS+=("$name")
    printf '%-42s %-14s %s\n' "$name" "*** SURVIVED ***" "0 — this rule is NOT tested"
  fi
  [ "$KEEP" = 1 ] || rm -rf "$dir"
done

printf '%s\n' "----------------------------------------------------------------------------------"
echo "killed $KILLED · survived $SURVIVED · not-applicable $NA · broken $BROKEN"
if [ "$NA" -gt 0 ]; then
  echo
  echo "NOT APPLICABLE (the pattern no longer matches — update tests/tools/mutations.py, do not"
  echo "assume the rule is covered):"
  printf '  %s\n' "${NA_LIST[@]}"
fi
if [ "$BROKEN" -gt 0 ]; then
  echo
  echo "BROKEN (the edit did not produce a runnable tree — fix the pattern, it proves nothing):"
  printf '  %s\n' "${BROKEN_LIST[@]}"
fi
if [ "$SURVIVED" -gt 0 ]; then
  echo
  echo "SURVIVORS — each of these can be deleted from the codebase with the suite still green:"
  for s in "${SURVIVORS[@]}"; do
    echo "  $s"
    "$PY" "$CATALOGUE" describe "$s" | sed 's/^/      /'
  done
  exit 1
fi
exit 0
