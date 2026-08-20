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

# refusal: the wanted exit code AND a reason on STDERR, with no traceback. A ZeroDivisionError
# also exits non-zero, so "it failed" is not the assertion -- "it refused, and said why" is.
expect_refusal() {
  local what="$1" want="$2" re="$3"; shift 3
  local err rc=0
  err="$($PY "$POWER" "$@" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" != "$want" ]; then bad "$what" "exit $rc, wanted $want"; return; fi
  if printf '%s' "$err" | grep -q 'Traceback (most recent call last)'; then
    bad "$what" "crashed instead of refusing: $(printf '%s' "$err" | tail -1)"; return
  fi
  if printf '%s' "$err" | $PY -c '
import re,sys
sys.exit(0 if re.search(sys.argv[1], sys.stdin.read(), re.S) else 1)' "$re"; then
    ok "$what"
  else
    bad "$what" "stderr did not match /$re/: $(printf '%s' "$err" | tr '\n' '|' | cut -c1-200)"
  fi
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
  'power AT the threshold \(\+3\.00%\) +50\.0%' \
  throughput --level c16 --reps 3 --threshold 3

# BUG A6: the two power lines used to share the label "power at +3.0%" and could carry
# DIFFERENT values under it (threshold 3.00 vs true effect 3.04, both formatted %.1f).
expect_match "the two power lines are distinguishable, not two 'power at +3.0%' rows" \
  'power AT the threshold \(\+3\.00%\) +50\.0%.*?power at the true effect \(\+3\.04%\) +50\.7%' \
  throughput --level c16 --reps 3 --threshold 3.0 --delta 3.04

# --- the warm-up bias is a BIAS, and --drop-first makes that reproducible with the tool ------
# The first bench of an experiment runs ~1.2% slow at c16; it inflates every bracket's CV and
# therefore every published MDE. This is the largest single improvement available to Gate 3 and
# it costs no GPU time, so it has to be checkable, not just asserted in a document.
expect_match "c16 pooled CV is 2.25% as-is" 'pooled CV 2\.25%' throughput --level c16
expect_match "c16 pooled CV is 1.55% with the first bench dropped" \
  'FIRST BENCH DROPPED.*pooled CV 1\.55%' throughput --level c16 --drop-first
expect_match "variance says loudly when it is dropping the first bench" \
  'FIRST BENCH OF EACH BRACKET DROPPED' variance --drop-first
expect_json "dropping the first bench lowers the c16 MDE below 5%" mde_pct 4.17 0.05 \
  throughput --level c16 --drop-first
# per-model: the two models whose CV is almost entirely warm-up
expect_json "Qwen3-8B c16 CV 3.05% -> 0.49% with the first bench dropped" cv 0.0049 0.0002 \
  throughput --level c16 --model RedHatAI/Qwen3-8B-NVFP4 --min-brackets 5 --drop-first
expect_json "VibeThinker c16 CV 3.09% -> 0.11%" cv 0.0011 0.0002 \
  throughput --level c16 --model WeiboAI/VibeThinker-3B --min-brackets 3 --drop-first

# --- refuses to invent a number where the repo has no replicates ----------------------------
expect_rc "c32 has no replicate brackets -> exit 4, no number" 4 throughput --level c32
expect_rc "c4 has no replicate brackets -> exit 4, no number" 4 throughput --level c4
expect_match "with an explicit --cv it will plan for c32 anyway" \
  'CV 5\.00%' \
  throughput --level c32 --cv 5.0

# --- a thin per-model filter falls back and SAYS SO ------------------------------------------
expect_match "thin model filter falls back loudly" \
  'FELL BACK' \
  throughput --level c16 --model WeiboAI/VibeThinker-3B --min-brackets 40

# --- BUG A2: --model is an EXACT, org-qualified match, not a substring -----------------------
# `Qwen3.6-35B-A3B-NVFP4` without the org also matched unsloth/...-Fast, silently pooling two
# models into one "per-model" variance estimate: 12 brackets / 0.61% instead of 11 / 0.58%.
expect_match "exact --model gives the 35B its own 11 brackets at 0.58%" \
  'pooled CV 0\.58%.*over 11 brackets' \
  throughput --level c16 --model RedHatAI/Qwen3.6-35B-A3B-NVFP4 --min-brackets 5
expect_refusal "an org-less model name is refused, not silently pooled with another org" 2 \
  'matches no row.*EXACT, org-qualified' \
  throughput --level c16 --model Qwen3.6-35B-A3B-NVFP4 --min-brackets 5
# the worst case of the old semantics: a substring shared by nine models pooled all of them
# into one "per-model" CV and reported it as if it belonged to one model.
expect_refusal "a bare quant suffix ('NVFP4') no longer pools nine models into one estimate" 2 \
  'matches no row' throughput --level c16 --model NVFP4
expect_refusal "keep-rule refuses an unknown --model too" 2 'matches no row' \
  keep-rule --model Qwen3.6-35B-A3B-NVFP4
expect_refusal "variance refuses an unknown --model too" 2 'matches no row' \
  variance --model Qwen3.6-35B-A3B-NVFP4

# --- BUG A3/A4: legitimate edge inputs answer; nonsense inputs REFUSE ------------------------
# p=0 is a real observation (think-off zero-token gsm8k=0.0) but a degenerate proportion.
expect_refusal "accuracy --p 0 refuses with a reason (was: ZeroDivisionError)" 2 \
  'degenerate proportion' accuracy --task gsm8k --limit 100 --p 0
expect_refusal "accuracy --p 1 refuses with a reason" 2 \
  'degenerate proportion' accuracy --task gsm8k --limit 100 --p 1
# cv=0 happens whenever two benches match exactly: ANSWER, in the zero-spread limit, with a
# caveat that a k=3 CV estimate of 0 is not evidence of a noiseless box.
expect_match "throughput --cv 0 answers in the zero-spread limit (was: ZeroDivisionError)" \
  'CV IS EXACTLY ZERO.*false-keep' throughput --level c16 --cv 0
expect_json "throughput --cv 0: false-keep is exactly 0" false_keep_prob 0 0 \
  throughput --level c16 --cv 0
expect_refusal "throughput --cv -5 refuses (was: a full report from |log1p(-.05)|)" 2 \
  'cannot be negative' throughput --level c16 --cv -5
expect_refusal "mcnemar --n below b+c refuses (was: psi = 3.3333, MDE 206.60 points)" 2 \
  'smaller than the 10 discordant pairs' mcnemar --b 5 --c 5 --n 3
expect_refusal "mcnemar with no pairs at all refuses (was: psi = nan)" 2 \
  'no pairs' mcnemar --b 0 --c 0
expect_refusal "mcnemar rejects negative counts" 2 'cannot be negative' mcnemar --b -1 --c 2
expect_refusal "accuracy rejects an out-of-range --discordance" 2 'fraction of items' \
  accuracy --task mmlu --limit 100 --discordance 1.5
expect_refusal "accuracy rejects a non-positive --delta" 2 'must be positive' \
  accuracy --task mmlu --limit 100 --delta 0
expect_refusal "throughput rejects an out-of-range --power" 2 'must be in .0,1.' \
  throughput --level c16 --cv 2 --power 1.0
# b=c=0 with a real n IS legitimate: two configs that agree on every item.
expect_match "mcnemar b=c=0 at a real n reports psi=0 and says the MDE is undefined" \
  'psi = 0\.0000.*MDE at this n/psi  undefined' mcnemar --b 0 --c 0 --n 5700

# --- BUG A5: a silently repaired psi must be SAID, not printed as the user's psi -------------
expect_match "psi<delta repair is announced beside the user's psi" \
  'psi = 0\.020.*psi RAISED to 0\.050' \
  accuracy --task mmlu --limit 100 --delta 5.0 --discordance 0.02
expect_json "the repair is in --json too" paired.discordance_repaired 1 0 \
  accuracy --task mmlu --limit 100 --delta 5.0 --discordance 0.02
expect_json "psi is NOT repaired when delta <= psi" paired.discordance_repaired 0 0 \
  accuracy --task mmlu --limit 100 --delta 1.0 --discordance 0.02

# --- exact McNemar, hand-computable: b=8,c=2 -> 2*P(X<=2|10,.5) = 112/1024 = 0.109375 --------
expect_json "exact McNemar p(b=8,c=2) = 0.109375" exact_p 0.109375 1e-9 mcnemar --b 8 --c 2
expect_match "McNemar verdict wording" 'not separable' mcnemar --b 8 --c 2
# b=30,c=5 -> 2 * sum(C(35,i), i=0..5) / 2^35 = 2*384168/34359738368 = 2.2361520678e-05
expect_json "exact McNemar p(b=30,c=5) = 2*384168/2^35" exact_p 2.2361520678e-05 1e-13 \
  mcnemar --b 30 --c 5
expect_json "McNemar discordance psi = (b+c)/n" discordance 0.035 1e-12 \
  mcnemar --b 30 --c 5 --n 1000

# --- BUG A1: --log_samples is ONE FILE PER LEAF and doc_id restarts at 0 in every one --------
# lm-eval writes samples_<leaf>_<timestamp>.jsonl per LEAF subtask, so mmlu@100 is 57 files a
# side. Keying on doc_id alone made every leaf overwrite the last: a 2-leaf x 5-doc input
# reported "pairs 5", and on a real run it would report n=100 while the operator believed
# n=5,700. The fixtures below are that exact shape.
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
$PY - "$FIX" <<'EOF'
import json,os,sys
S=sys.argv[1]; TS="_2026-08-20T01-02-03.000000.jsonl"
for side in ("A","B"): os.makedirs(os.path.join(S,side))
def w(p,recs):
    with open(p,"w") as f:
        for r in recs: f.write(json.dumps(r)+"\n")
# doc_id restarts at 0 in BOTH leaves -- that is the whole point
w(os.path.join(S,"A","samples_mmlu_abstract_algebra"+TS), [{"doc_id":i,"acc":1.0} for i in range(5)])
w(os.path.join(S,"A","samples_mmlu_anatomy"+TS),          [{"doc_id":i,"acc":1.0} for i in range(5)])
w(os.path.join(S,"B","samples_mmlu_abstract_algebra"+TS), [{"doc_id":i,"acc":0.0 if i==0 else 1.0} for i in range(5)])
w(os.path.join(S,"B","samples_mmlu_anatomy"+TS),          [{"doc_id":i,"acc":0.0 if i<2 else 1.0} for i in range(5)])
# side B missing a leaf, to prove the tool refuses to intersect silently
w(os.path.join(S,"B_short"+TS), [{"doc_id":i,"acc":1.0} for i in range(5)])
# what an operator does today to satisfy a two-file CLI: cat the leaves together
for side in ("A","B"):
    with open(os.path.join(S,side+"_cat.jsonl"),"w") as f:
        for leaf in ("abstract_algebra","anatomy"):
            f.write(open(os.path.join(S,side,"samples_mmlu_"+leaf+TS)).read())
EOF
A1="$FIX/A/samples_mmlu_abstract_algebra_2026-08-20T01-02-03.000000.jsonl"
A2="$FIX/A/samples_mmlu_anatomy_2026-08-20T01-02-03.000000.jsonl"
B1="$FIX/B/samples_mmlu_abstract_algebra_2026-08-20T01-02-03.000000.jsonl"
B2="$FIX/B/samples_mmlu_anatomy_2026-08-20T01-02-03.000000.jsonl"

expect_json "N files per side: 2 leaves x 5 docs = 10 pairs, not 5" n 10 0 \
  mcnemar --samples-a "$A1" "$A2" --samples-b "$B1" "$B2"
expect_json "the discordant count survives the second leaf (b=3, not 2)" b 3 0 \
  mcnemar --samples-a "$A1" "$A2" --samples-b "$B1" "$B2"
expect_match "it names the leaf tasks it pooled" \
  'over 2 leaf task\(s\): mmlu_abstract_algebra, mmlu_anatomy' \
  mcnemar --samples-a "$A1" "$A2" --samples-b "$B1" "$B2"
expect_json "one leaf on its own is still 5 pairs" n 5 0 \
  mcnemar --samples-a "$A1" --samples-b "$B1"
expect_json "the legacy two-file --samples form still works" n 5 0 \
  mcnemar --samples "$A1" "$B1"
# a hand-concatenated file is a duplicate-key error, not a quietly halved n
expect_refusal "hand-concatenated leaves are refused, not silently deduplicated" 2 \
  'duplicate \(task, doc_id\)' \
  mcnemar --samples-a "$FIX/A_cat.jsonl" --samples-b "$FIX/B_cat.jsonl"
# BUG A6: mismatched sides used to intersect in silence
expect_refusal "mismatched sides refuse rather than intersecting silently" 2 \
  'do not cover the same items' \
  mcnemar --samples-a "$A1" "$A2" --samples-b "$B1"
expect_json "--allow-partial tests the shared items and says how many" n 5 0 \
  mcnemar --allow-partial --samples-a "$A1" "$A2" --samples-b "$B1"
expect_match "--allow-partial prints a PARTIAL banner" '!! PARTIAL +5 item\(s\) only in A' \
  mcnemar --allow-partial --samples-a "$A1" "$A2" --samples-b "$B1"

# --- keep-rule and variance render against the live journals ---------------------------------
expect_match "keep-rule scores both levels" 'c16 +pooled CV' keep-rule
expect_match "keep-rule states the 50% property" 'fires\s*$|about half the time' keep-rule
expect_match "variance names the accuracy bracket shortage" \
  'that is the ENTIRE empirical basis' variance
expect_match "variance reports cross-day scope" 'cross +c1' variance

# --- `seed` needs the raw bundles, which are gitignored. Skip loudly, never silently. --------
# A worktree has no bundles even when the main checkout does, so allow an explicit override:
#   AHL_POWER_DATA_ROOT=/path/to/checkout-with-results bash scripts/power_selftest.sh
DATA_ROOT="${AHL_POWER_DATA_ROOT:-$REPO_ROOT}"
BUNDLE="$(find "$DATA_ROOT/results" -path '*/data/*-chat/level_c1.json' -print -quit 2>/dev/null || true)"
if [ -n "$BUNDLE" ]; then
  expect_match "seed: reports both variance components and the c16 projection" \
    'workload SD.*?c16 projection' --root "$DATA_ROOT" seed --boot 40
  expect_json "seed: ragged-tail residual is small but nonzero" ragged_tail_cv 0.0012 0.0012 \
    --root "$DATA_ROOT" seed --boot 40
  # the three caveats item 12 of the audit asked for, asserted rather than promised
  expect_match "seed: says its bootstrap statistic is NOT the estimator the journal records" \
    "bootstrap statistic is sum\(tokens\)/sum\(latency\).*token-level mean" \
    --root "$DATA_ROOT" seed --boot 40
  expect_match "seed: says a time-limited stage makes n random, which a fixed-n bootstrap misses" \
    'TIME-limited.*fixed-n bootstrap' --root "$DATA_ROOT" seed --boot 40
  expect_match "seed: quotes the ragged tail over the WIDE 60-100% window too" \
    'ragged-tail residual   85-100%.*60-100%' --root "$DATA_ROOT" seed --boot 40
  expect_match "seed: labels the pooled band MIXED BASIS instead of implying like-for-like" \
    'planning \(MIXED BASIS\).*MIXED BASIS and is an upper band' \
    --root "$DATA_ROOT" seed --boot 40
else
  echo "  skip seed (raw bundles are gitignored and absent under $DATA_ROOT/results;"
  echo "             re-run as: AHL_POWER_DATA_ROOT=<checkout-with-data> bash \$0)"
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
