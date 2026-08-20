#!/usr/bin/env bash
# power_selftest.sh — acceptance gate for scripts/power.py.
#
# Two halves:
#   1. `power.py selftest` — the numeric core against hand-computable values, published table
#      values (Student-t, Clopper-Pearson, Fleiss's n=58, Connor's n=469) and seeded Monte Carlo.
#   2. this file — the CLI contract: exit codes, JSON shape, refusal to invent a number where
#      the repo has no replicates, and the arithmetic an operator will actually read off the
#      screen. A statistics tool that is subtly wrong is worse than none, because it is believed.
#
# Hermetic: stdlib python only, no GPU, no network, no docker, no lm-eval. ~20 s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POWER="$SCRIPT_DIR/power.py"

PY="${AHL_PYTHON:-}"
if [ -z "$PY" ]; then
  if command -v uv >/dev/null 2>&1; then PY="uv run --project $REPO_ROOT --quiet python"
  else PY="python3"; fi
fi

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# assert that running power.py with the given args produces stdout matching a regex.
# Matching is done in python with re.S so a pattern may legitimately span lines -- grep is
# line-oriented and silently never matches a multi-line pattern, which is exactly the kind of
# always-green assertion this repo has been bitten by.
expect_match() {
  local what="$1" re="$2"; shift 2
  local out rc=0
  out="$($PY "$POWER" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then bad "$what" "exit $rc: $(printf '%s' "$out" | tail -2)"; return; fi
  if printf '%s' "$out" | $PY -c '
import re,sys
sys.exit(0 if re.search(sys.argv[1], sys.stdin.read(), re.S) else 1)' "$re"; then
    ok "$what"
  else
    bad "$what" "no match for /$re/ in: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-260)"
  fi
}

# the matcher must be able to FAIL, and must be able to match across lines
selfcheck_matcher() {
  local rc=0
  printf 'alpha\nbeta\n' | $PY -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.stdin.read(), re.S) else 1)' 'alpha.*beta' || rc=1
  [ "$rc" = 0 ] || { bad "matcher spans lines" "it does not"; return; }
  rc=0
  printf 'alpha\n' | $PY -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.stdin.read(), re.S) else 1)' 'zzz' || rc=1
  [ "$rc" = 1 ] && ok "matcher spans lines and can still fail" || bad "matcher can fail" "it cannot"
}

expect_rc() {
  local what="$1" want="$2"; shift 2
  local rc=0
  $PY "$POWER" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then ok "$what"; else bad "$what" "exit $rc, wanted $want"; fi
}

# assert a numeric field of --json output, via a tiny stdlib reader
expect_json() {
  local what="$1" path="$2" want="$3" tol="$4"; shift 4
  local got
  got="$($PY "$POWER" --json "$@" 2>/dev/null | $PY -c '
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(float(d))' "$path")" || { bad "$what" "could not read $path"; return; }
  if $PY -c '
import sys
g,w,t=float(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3])
sys.exit(0 if abs(g-w)<=t else 1)' "$got" "$want" "$tol"; then
    ok "$what ($path=$got)"
  else
    bad "$what" "$path=$got wanted $want +/- $tol"
  fi
}

echo "== 1. numeric core =="
if $PY "$POWER" selftest; then ok "power.py selftest"; else bad "power.py selftest" "see above"; fi

echo
echo "== 2. CLI contract =="
selfcheck_matcher

# --- the LIMIT=100 arithmetic, which is the whole point of the tool -------------------------
expect_match "mmlu@100 reports n=5,700 not 100" 'effective n +5,700' \
  accuracy --task mmlu --limit 100
expect_match "gsm8k@100 reports n=100" 'effective n +100 ' \
  accuracy --task gsm8k --limit 100
expect_match "mmlu_pro@100 reports n=1,400" 'effective n +1,400' \
  accuracy --task mmlu_pro --limit 100

# --- hand-checkable binomial SE: sqrt(.82*.18/5700) = 0.005089 -> 0.509 points --------------
expect_json "mmlu@100 binomial SE = 0.509 points" se_points 0.509 0.002 \
  accuracy --task mmlu --limit 100 --p 0.82

# --- the headline verdicts the recommendation rests on --------------------------------------
expect_match "gsm8k@100 cannot resolve 1 point, unpaired" \
  'UNPAIRED.*?CANNOT resolve 1\.00 points' \
  accuracy --task gsm8k --limit 100 --delta 1.0
expect_match "mmlu@100 paired at psi=.02 CAN resolve 1 point" \
  'PAIRED / McNemar.*?[^T]CAN resolve 1\.00 points' \
  accuracy --task mmlu --limit 100 --delta 1.0 --discordance 0.02
expect_match "mmlu@100 unpaired CANNOT resolve 1 point" \
  'UNPAIRED.*?CANNOT resolve 1\.00 points.*?PAIRED' \
  accuracy --task mmlu --limit 100 --delta 1.0
expect_json "mmlu@100 paired at psi=.02 resolves; json agrees" paired.resolves 1 0 \
  accuracy --task mmlu --limit 100 --delta 1.0 --discordance 0.02
expect_json "mmlu@100 unpaired does not resolve; json agrees" unpaired.resolves 0 0 \
  accuracy --task mmlu --limit 100 --delta 1.0
expect_json "gsm8k@100 unpaired does not resolve; json agrees" unpaired.resolves 0 0 \
  accuracy --task gsm8k --limit 100 --delta 1.0

# --- --relative changes the question, and is visible in the output --------------------------
expect_json "--relative 1% of p=.82 is 0.82 points" delta_points 0.82 0.001 \
  accuracy --task mmlu --limit 100 --p 0.82 --delta 1.0 --relative

# --- throughput: reads the repo's own brackets ----------------------------------------------
expect_match "c16 throughput cites bracket count + df" \
  'pooled CV [0-9.]+%.*over [0-9]+ brackets / [0-9]+ df' \
  throughput --level c16
expect_match "estimator is a median of N, not a mean" \
  'estimator SD +0\.6698 x sigma' \
  throughput --level c16 --reps 3
expect_match "power at the KEEP threshold is 50%" \
  'power at \+3\.0% +50\.0%' \
  throughput --level c16 --reps 3 --threshold 3

# --- refuses to invent a number where the repo has no replicates ----------------------------
expect_rc "c32 has no replicate brackets -> exit 4, no number" 4 throughput --level c32
expect_rc "c4 has no replicate brackets -> exit 4, no number" 4 throughput --level c4
expect_match "with an explicit --cv it will plan for c32 anyway" \
  'CV 5\.00%' \
  throughput --level c32 --cv 5.0

# --- a thin per-model filter falls back and SAYS SO ------------------------------------------
expect_match "thin model filter falls back loudly" \
  'FELL BACK' \
  throughput --level c16 --model VibeThinker --min-brackets 40

# --- exact McNemar, hand-computable: b=8,c=2 -> 2*P(X<=2|10,.5) = 112/1024 = 0.109375 --------
expect_json "exact McNemar p(b=8,c=2) = 0.109375" exact_p 0.109375 1e-9 mcnemar --b 8 --c 2
expect_match "McNemar verdict wording" 'not separable' mcnemar --b 8 --c 2
# b=30,c=5 -> 2 * sum(C(35,i), i=0..5) / 2^35 = 2*384168/34359738368 = 2.2361520678e-05
expect_json "exact McNemar p(b=30,c=5) = 2*384168/2^35" exact_p 2.2361520678e-05 1e-13 \
  mcnemar --b 30 --c 5
expect_json "McNemar discordance psi = (b+c)/n" discordance 0.035 1e-12 \
  mcnemar --b 30 --c 5 --n 1000

# --- keep-rule and variance render against the live journals ---------------------------------
expect_match "keep-rule scores both levels" 'c16 +pooled CV' keep-rule
expect_match "keep-rule states the 50% property" 'fires\s*$|about half the time' keep-rule
expect_match "variance names the accuracy bracket shortage" \
  'that is the ENTIRE empirical basis' variance
expect_match "variance reports cross-day scope" 'cross +c1' variance

# --- `seed` needs the raw bundles, which are gitignored. Skip loudly, never silently. --------
BUNDLE="$(find "$REPO_ROOT/results" -path '*/data/*-chat/level_c1.json' -print -quit 2>/dev/null || true)"
if [ -n "$BUNDLE" ]; then
  expect_match "seed: reports both variance components and the c16 projection" \
    'workload SD.*?c16 projection' seed --boot 40
  expect_json "seed: ragged-tail residual is small but nonzero" ragged_tail_cv 0.0012 0.0012 \
    seed --boot 40
else
  echo "  skip seed (raw bundles are gitignored and absent under $REPO_ROOT/results;"
  echo "             re-run as: scripts/power.py --root <checkout-with-data> seed)"
fi

# --- json mode is valid json for every subcommand that has one -------------------------------
for sub in "accuracy --task mmlu --limit 100" "throughput --level c16" "keep-rule" "variance" \
           "mcnemar --b 3 --c 1"; do
  # shellcheck disable=SC2086
  if $PY "$POWER" --json $sub 2>/dev/null | $PY -c 'import json,sys; json.load(sys.stdin)'; then
    ok "--json $sub parses"
  else
    bad "--json $sub parses" "not valid json"
  fi
done

# --- monotonicity an operator would notice if it were backwards ------------------------------
$PY - "$POWER" <<'EOF' && ok "monotonicity: more reps -> smaller MDE, more n -> smaller MDE" \
  || bad "monotonicity" "see message above"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("power", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import math
assert m.mde_throughput(0.02, 3, 3) > m.mde_throughput(0.02, 9, 9) > m.mde_throughput(0.02, 25, 25)
assert m.mde_two_prop(100, 0.9) > m.mde_two_prop(1000, 0.9) > m.mde_two_prop(10000, 0.9)
# psi=0.05 caps the detectable difference at 5 points, and n=100 cannot reach it -> NaN,
# which is the honest answer, not a number. Use a psi where all three n are in range.
assert math.isnan(m.mde_mcnemar(100, 0.05))
assert m.mde_mcnemar(500, 0.20) > m.mde_mcnemar(1000, 0.20) > m.mde_mcnemar(10000, 0.20)
# a bigger discordance is strictly worse at fixed n
assert m.mde_mcnemar(5700, 0.02) < m.mde_mcnemar(5700, 0.10)
# and the paired test beats the unpaired one at the same n whenever psi < 2pq (= 0.295 here)
assert m.mde_mcnemar(5700, 0.10) < m.mde_two_prop(5700, 0.82)
# n_two_prop and n_mcnemar are both decreasing in the difference asked for
assert m.n_two_prop(0.82, 0.80) < m.n_two_prop(0.82, 0.81)
assert m.n_mcnemar(0.05, 0.02) < m.n_mcnemar(0.05, 0.01)
EOF

# --- the arithmetic behind the recommendation, checked end to end -----------------------------
$PY - "$POWER" "$REPO_ROOT" <<'EOF' && ok "recommendation arithmetic reproduces" || bad "recommendation arithmetic" ""
import importlib.util, sys, math
spec = importlib.util.spec_from_file_location("power", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# NOTE all mde_* return PROPORTIONS, not points: 1 point is 0.01.
# 1. unpaired mmlu needs more items for a 1-point rule than mmlu HAS
need = m.n_two_prop(0.82, 0.81)
assert need > m.TASK_FULL_N["mmlu"], need
# 2. paired mmlu@100 (n=5700) clears ~1 point across the defensible psi range
for psi in (0.02, 0.05, 0.10):
    got = m.mde_mcnemar(5700, psi)
    assert got <= 0.0125, (psi, got)
# 3. gsm8k@100 cannot clear 1 point under ANY discordance
assert all(math.isnan(m.mde_mcnemar(100, psi)) or m.mde_mcnemar(100, psi) > 0.01
           for psi in (0.02, 0.05, 0.10, 0.20, 0.40))
# 4. mmlu is ~12x cheaper per sample than gsm8k -- why the cheap gate is the precise one
assert m.TASK_SECONDS_PER_SAMPLE["gsm8k"] / m.TASK_SECONDS_PER_SAMPLE["mmlu"] > 10
# 5. the c16 KEEP rule at N=3 cannot resolve its own 3% threshold on this repo's spread
br = m.throughput_brackets(sys.argv[2], "c16", None, "chat", "experiment")
cv = m.pooled_cv(br)
assert 0.015 < cv < 0.035, cv
assert m.mde_throughput(cv, 3, 3) > 0.05, m.mde_throughput(cv, 3, 3)
assert m.false_keep_prob(0.03, cv, 3, 3) > 0.05
EOF

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
