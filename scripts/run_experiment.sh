#!/usr/bin/env bash
# run_experiment.sh <runbook.sh> — one autoresearch experiment: serve ONCE, bench N times
# (amortizing the load tax), tear down, and report the median c16 (objective) + c1 (sentinel).
#
#   N=3 EXP_SHAPE=chat LEVELS_SET=1,16 MAX_SECONDS=180 scripts/run_experiment.sh <runbook.sh>
#
# Prints a one-line summary and the median to stdout:  MEDIAN c16=<x> c1=<y> n=<k> status=<ok|crash>
# Rows land in results.tsv tagged `exp=<id>` so the median is computed over exactly this run's
# benches. The keep/discard decision is the caller's (compare to current best via tune_status.py).
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
  echo "MEDIAN c16=na c1=na n=0 status=serve_fail"; exit 1; }

# Gate 1 (functional): cheap smoke before spending benchmark time on a broken config.
if [ "${SKIP_SMOKE:-0}" != 1 ]; then
  "$SCRIPT_DIR/smoke.sh" "$RUNBOOK" || {
    "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true
    echo "MEDIAN c16=na c1=na n=0 status=smoke_fail"; exit 1; }
fi

status=ok ok=0
for n in $(seq 1 "$N"); do
  echo ">> bench $n/$N" >&2
  if STATUS=measured NOTES="exp=$EXP_ID n$n" "$SCRIPT_DIR/bench.sh" "$RUNBOOK" "$EXP_SHAPE"; then
    ok=$((ok + 1))
  else
    status=crash; echo ">> bench $n crashed/hung — server torn down, stopping experiment" >&2; break
  fi
done
[ "$status" = ok ] && { "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true; }

# Median over this experiment's rows (tagged exp=$EXP_ID), for the objective shape.
read -r MC1 MC16 NC < <(python3 - "$TSV" "$EXP_ID" "$EXP_SHAPE" <<'PY'
import sys, csv, statistics
tsv, exp, shape = sys.argv[1:4]
c1, c16 = [], []
try:
    rows = list(csv.DictReader(open(tsv), delimiter='\t'))
except FileNotFoundError:
    rows = []
for r in rows:
    if exp in r.get('notes', '') and r.get('shape', '').startswith(shape):
        for col, acc in (('tps_c1', c1), ('tps_c16', c16)):
            try: acc.append(float(r[col]))
            except (ValueError, TypeError): pass
med = lambda x: round(statistics.median(x), 2) if x else 'na'
print(med(c1), med(c16), len(c16))
PY
)

echo "MEDIAN c16=$MC16 c1=$MC1 n=$NC status=$status"
