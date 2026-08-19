#!/usr/bin/env bash
# run_experiment.sh <runbook.sh> — one autoresearch experiment: serve ONCE, bench N times
# (amortizing the load tax), tear down, and report the median c16 (objective) + c1 (sentinel).
#
#   N=3 EXP_SHAPE=chat LEVELS_SET=1,16 MAX_SECONDS=180 scripts/run_experiment.sh <runbook.sh>
#
# Prints a one-line summary and the median to stdout:
#   MEDIAN c16=<x> c1=<y> n=<k> status=<ok|crash|...> cite=<ok|partial|insufficient|no_valid_data> \
#          valid=<k>/<rows> void=<a> suspect=<b> crash=<c> obj=<col> [lone_<col>=<v>]
# Rows land in results.tsv tagged `exp=<id>` so the median is computed over exactly this run's
# benches. The keep/discard decision is the caller's (compare to current best via tune_status.py).
#
# ── MEASUREMENT VALIDITY (docs/validity-contract.md §5/§6) ────────────────────
# `status=measured` no longer means "a row exists", it means the invariants passed. This script is
# the project's keep/discard primitive, so it must never launder a bad row into a median:
#
#   void     row = NOT DATA. Excluded from the median entirely, never counted toward N.
#   suspect  row = measured but an invariant questions it. ALSO excluded from the median (contract
#                  §5: "run_experiment.sh refuses to compute a median over them") and reported
#                  loudly on stderr + in the summary line's `suspect=` field. There is deliberately
#                  NO include-anyway switch here: adjudicating a questionable row is a human act,
#                  and the place for it is promote.sh's AHL_PROMOTE_OVERRIDE, where the decision is
#                  recorded in the promoted artifact forever. A tuning loop must not self-authorize.
#   crash    row = engine wedge. Excluded (its level columns are `hang` anyway) and counted.
#
# PARTIAL-SET POLICY (k valid rows out of N):
#   k == N     -> cite=ok          median reported, exit 0.
#   2 <= k < N -> cite=partial     median reported, exit 0. A median over 2 is weaker than over 3,
#                 but the rule AGENTS.md actually states is "don't act on a SINGLE run"; two repeats
#                 still bound the noise, and the summary line carries valid=k/rows so the caller
#                 (and the logbook) can see the set was short. We do NOT top the set back up to N:
#                 "don't change N mid-run" — silently re-benching until 3 rows survive would bias
#                 the set toward whatever the box was doing when it felt healthy.
#   k == 1     -> cite=insufficient. NO median is printed (c16=na); the lone value is reported
#                 separately as `lone_<obj>=` so a human can see it but no caller can mistake it for
#                 a median. Exit 4.
#   k == 0     -> cite=no_valid_data. Exit 4.
# Exit codes: 0 citable, 1 serve/smoke failure (pre-measurement), 4 measurement not citable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNBOOK="${1:?usage: run_experiment.sh <runbook.sh>}"
[ -f "$RUNBOOK" ] || { echo "runbook not found: $RUNBOOK" >&2; exit 1; }
N="${N:-3}"
export EXP_SHAPE="${EXP_SHAPE:-chat}"
export LEVELS_SET="${LEVELS_SET:-1,16}"     # c1 sentinel + c16 objective
export MAX_SECONDS="${MAX_SECONDS:-180}"
EXP_ID="$(date -u +%Y%m%d-%H%M%S)"

# Identify the (node,model) results.tsv this runbook writes to.
MODEL=""; # shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
TSV="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME/results.tsv"

echo ">> experiment $EXP_ID: $RUNBOOK  (N=$N, shape=$EXP_SHAPE, levels=$LEVELS_SET, max_s=$MAX_SECONDS)" >&2
"$SCRIPT_DIR/serve.sh" "$RUNBOOK" >/dev/null 2>"$REPO_ROOT/.ahl_exp_serve.log" || {
  echo "MEDIAN c16=na c1=na n=0 status=serve_fail cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 obj=c16"; exit 1; }

# Gate 1 (functional): cheap smoke before spending benchmark time on a broken config.
if [ "${SKIP_SMOKE:-0}" != 1 ]; then
  "$SCRIPT_DIR/smoke.sh" "$RUNBOOK" || {
    "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true
    echo "MEDIAN c16=na c1=na n=0 status=smoke_fail cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 obj=c16"; exit 1; }
fi

# bench.sh exit codes: 0 ok · 3 crash/hang (server torn down) · 4 validity failure (row WAS written,
# but the numbers are not citable). 3 stops the experiment (the box is broken and the container is
# gone); 4 does NOT — the run is simply one repetition short, which is exactly the partial set the
# policy above is for. Anything else non-zero is treated like 3: server state is unknown.
crashed=0 ok=0 invalid=0
for n in $(seq 1 "$N"); do
  echo ">> bench $n/$N" >&2
  rc=0
  STATUS=measured NOTES="exp=$EXP_ID n$n" "$SCRIPT_DIR/bench.sh" "$RUNBOOK" "$EXP_SHAPE" || rc=$?
  case "$rc" in
    0) ok=$((ok + 1)) ;;
    4) invalid=$((invalid + 1))
       echo ">> !! bench $n: VALIDITY FAILURE (exit 4) — row written but NOT citable; continuing" >&2 ;;
    3) crashed=1; echo ">> bench $n crashed/hung — server torn down, stopping experiment" >&2; break ;;
    *) crashed=1; echo ">> bench $n failed (exit $rc) — stopping experiment" >&2; break ;;
  esac
done
[ "$crashed" = 0 ] && { "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true; }
echo ">> benches: ok=$ok validity_failed=$invalid crashed=$crashed (N=$N)" >&2

# Median over this experiment's rows (tagged exp=$EXP_ID), for the objective shape. Kept textually
# identical to the block in run_experiment_llamacpp.sh — one rule, two backends.
read -r MC1 MC16 NC NVOID NSUSP NCRASH NROWS OBJ LONE VERDICT < <(python3 - "$TSV" "$EXP_ID" "$EXP_SHAPE" <<'PY'
import sys, csv, statistics
tsv, exp, shape = sys.argv[1:4]
# Validity vocabulary (docs/validity-contract.md §3/§6). `status` is the adjudicated verdict;
# `validity` is the evidence. Trust the downgraded status, and ALSO re-derive from the verdict
# tokens so a row written by a bench that recorded validity but failed to downgrade cannot slip in.
FATAL = {'no_data', 'over_roofline'}

def classify(r):
    st = (r.get('status') or '').strip().lower()
    if st in ('void', 'suspect', 'crash'):
        return st
    toks = [t for t in (r.get('validity') or '').replace('+', ' ').split()
            if t and t not in ('ok', 'na')]
    if any(t in FATAL for t in toks):
        return 'void'
    if toks:                       # known-suspect OR unrecognized token -> conservative
        return 'suspect'
    return 'valid'

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

try:
    rows = list(csv.DictReader(open(tsv), delimiter='\t'))
except FileNotFoundError:
    rows = []
mine = [r for r in rows
        if exp in (r.get('notes') or '') and (r.get('shape') or '').startswith(shape)]
cls = [(r, classify(r)) for r in mine]
n_void    = sum(1 for _, c in cls if c == 'void')
n_suspect = sum(1 for _, c in cls if c == 'suspect')
n_crash   = sum(1 for _, c in cls if c == 'crash')
valid = [r for r, c in cls if c == 'valid']
c1  = [v for v in (num(r.get('tps_c1'))  for r in valid) if v is not None]
c16 = [v for v in (num(r.get('tps_c16')) for r in valid) if v is not None]
# Objective is c16; fall back to c1 only when c16 was never a RUN level (e.g. LEVELS_SET=1).
obj_name, obj = ('c16', c16) if c16 else ('c1', c1)
n = len(obj)
if   n == 0: verdict = 'no_valid_data'
elif n == 1: verdict = 'insufficient'
elif n < len(mine) or n_void or n_suspect or n_crash: verdict = 'partial'
else:        verdict = 'ok'
med = lambda x: round(statistics.median(x), 2) if x else 'na'
print(med(c1) if n >= 2 else 'na',
      med(c16) if n >= 2 else 'na',
      n, n_void, n_suspect, n_crash, len(mine), obj_name,
      (round(obj[0], 2) if n == 1 else 'na'), verdict)
PY
)

# The bench loop's view (crash) and the journal's view (validity) are separate axes; report the
# worse of the two in `status=` and always publish the counts so nothing is hidden behind one token.
# Two independent axes, both published: `status=` keeps its historical meaning (ok | crash | the
# pre-measurement failures) so existing run-queue tables keep working, and `cite=` carries the new
# citability verdict. A crash is the louder operator signal, so it wins `status=`; the citability
# verdict is never lost because it always has its own field (and c16=na when there is no median).
status="$VERDICT"
[ "$crashed" = 1 ] && status=crash
[ "$NVOID" != 0 ]  && echo ">> !! $NVOID VOID row(s) in this experiment — excluded from the median (not data)" >&2
[ "$NSUSP" != 0 ]  && echo ">> !! $NSUSP SUSPECT row(s) in this experiment — excluded from the median; adjudicate before citing" >&2
case "$VERDICT" in
  insufficient) echo ">> !! only 1 valid bench — refusing to call it a median (AGENTS.md: don't act on a single run)" >&2 ;;
  no_valid_data) echo ">> !! no valid bench rows — this experiment produced no citable measurement" >&2 ;;
esac

LINE="MEDIAN c16=$MC16 c1=$MC1 n=$NC status=$status cite=$VERDICT valid=$NC/$NROWS void=$NVOID suspect=$NSUSP crash=$NCRASH obj=$OBJ"
[ "$LONE" != na ] && LINE="$LINE lone_$OBJ=$LONE"
echo "$LINE"
case "$VERDICT" in insufficient|no_valid_data) exit 4 ;; esac
exit 0
