#!/usr/bin/env bash
# run_experiment_llamacpp.sh <runbook-stub.sh> — one autoresearch experiment on the llama.cpp
# HOST-process backend: (re)serve ONCE via the launcher, smoke-gate, bench N times (amortizing the
# load tax), and report the median c16 (objective) + c1 (sentinel).
#
#   TAG=<slug> N=3 MTP_DRAFT=3 scripts/run_experiment_llamacpp.sh <stub.sh>
#
# Sibling of run_experiment.sh, which is vLLM-only (it calls serve.sh / an adapter). Here the
# config lives in LAUNCHER's env knobs (QUANT / MTP / MTP_DRAFT / NP / CTX_PER_SLOT), so this
# script just passes the environment through and lets the launcher build the cmdline; the actual
# served cmdline is what bench_llamacpp.sh hashes into config_hash. See AGENTS.md ->
# "HOST-PROCESS backends (GGUF)".
#
# Env: TAG (required, lands in notes), N (3), LAUNCHER (the FF711 launcher next to the stub),
#      EXP_SHAPE (chat), LEVELS_SET (1,16), MAX_SECONDS (180), SKIP_SMOKE (0),
#      RESTART (1; set 0 to bench the already-running server as-is),
#      READY_TIMEOUT (300s to load weights + warm up).
# Prints:
#   MEDIAN c16=<x> c1=<y> n=<k> status=<ok|crash|...> cite=<ok|partial|insufficient|no_valid_data> \
#          valid=<k>/<rows> void=<a> suspect=<b> crash=<c> obj=<col> [lone_<col>=<v>]
#
# ── MEASUREMENT VALIDITY (docs/validity-contract.md §5/§6) ────────────────────
# Identical policy to run_experiment.sh — the rule is the project's, not the backend's:
#   void / suspect / crash rows are EXCLUDED from the median (a suspect row is reported loudly and
#   never silently averaged; adjudicating one is a human act, recorded at promote time).
# PARTIAL-SET POLICY (k valid rows out of N):
#   k == N -> cite=ok · 2 <= k < N -> cite=partial (median still reported; the set is short, not invented)
#   k == 1 -> cite=insufficient (NO median; the lone value is reported as lone_<obj>=) · k == 0 ->
#   cite=no_valid_data. Both refuse a median and exit 4. The set is never topped back up to N
#   ("don't change N mid-run" — re-benching until 3 rows survive biases the set).
# Exit codes: 0 citable, 1 serve/smoke failure (pre-measurement), 4 measurement not citable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STUB="${1:?usage: TAG=<slug> run_experiment_llamacpp.sh <runbook-stub.sh>}"
[ -f "$STUB" ] || { echo "stub not found: $STUB" >&2; exit 1; }
TAG="${TAG:?set TAG=<config-slug> (e.g. q5km-mtp-d3)}"
N="${N:-3}"
export EXP_SHAPE="${EXP_SHAPE:-chat}"
export LEVELS_SET="${LEVELS_SET:-1,16}"
export MAX_SECONDS="${MAX_SECONDS:-180}"
LAUNCHER="${LAUNCHER:-${STUB%.smoke-runbook.sh}.sh}"
TARGET="http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}"
EXP_ID="$(date -u +%Y%m%d-%H%M%S)"

MODEL=""; # shellcheck disable=SC1090
source "$STUB"; : "${MODEL:?stub must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
TSV="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME/results.tsv"

echo ">> experiment $EXP_ID [$TAG]: $LAUNCHER (N=$N, shape=$EXP_SHAPE, levels=$LEVELS_SET, max_s=$MAX_SECONDS)" >&2

FAILLINE="cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 obj=c16"
if [ "${RESTART:-1}" = 1 ]; then
  [ -x "$LAUNCHER" ] || { echo "launcher not executable: $LAUNCHER" >&2; exit 1; }
  "$LAUNCHER" >&2 || { echo "MEDIAN c16=na c1=na n=0 status=serve_fail $FAILLINE"; exit 1; }
  # Weights load asynchronously; poll the endpoint the benchmark will actually hit.
  waited=0
  until curl -sf -m 5 "$TARGET/v1/models" >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    if [ "$waited" -ge "${READY_TIMEOUT:-300}" ]; then
      echo ">> server never became ready after ${waited}s" >&2
      echo "MEDIAN c16=na c1=na n=0 status=serve_fail $FAILLINE"; exit 1
    fi
  done
  echo ">> ready after ${waited}s" >&2
fi

# Gate 1 (functional) before spending benchmark time on a broken config.
if [ "${SKIP_SMOKE:-0}" != 1 ]; then
  "$SCRIPT_DIR/smoke.sh" "$STUB" >&2 || { echo "MEDIAN c16=na c1=na n=0 status=smoke_fail $FAILLINE"; exit 1; }
fi

# bench_llamacpp.sh exit codes mirror bench.sh: 0 ok · 3 crash/hang · 4 validity failure (the row IS
# written, but is not citable). 4 does NOT stop the experiment — it just costs one repetition, which
# the partial-set policy above is designed for. 3 (or any other non-zero) stops it.
crashed=0 ok=0 invalid=0
for n in $(seq 1 "$N"); do
  echo ">> bench $n/$N" >&2
  rc=0
  TAG="$TAG" NOTES="exp=$EXP_ID n$n" "$SCRIPT_DIR/bench_llamacpp.sh" "$STUB" "$EXP_SHAPE" >&2 || rc=$?
  case "$rc" in
    0) ok=$((ok + 1)) ;;
    4) invalid=$((invalid + 1))
       echo ">> !! bench $n: VALIDITY FAILURE (exit 4) — row written but NOT citable; continuing" >&2 ;;
    3) crashed=1; echo ">> bench $n crashed/hung — stopping experiment" >&2; break ;;
    *) crashed=1; echo ">> bench $n failed (exit $rc) — stopping experiment" >&2; break ;;
  esac
  # A crash row may also be written by bench_llamacpp.sh while it exits 0 (a logged hang); catch it.
  if tail -1 "$TSV" | grep -q $'\tcrash\t'; then
    crashed=1; echo ">> bench $n logged a crash row — stopping experiment" >&2; break
  fi
done
echo ">> benches: ok=$ok validity_failed=$invalid crashed=$crashed (N=$N)" >&2

# Median over this experiment's rows (tagged exp=$EXP_ID), for the objective shape. Kept textually
# identical to the block in run_experiment.sh — one rule, two backends.
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

# `status=` keeps its historical meaning (ok | crash | pre-measurement failure) so existing
# run-queue tables keep working; `cite=` carries the new citability verdict. A crash wins `status=`
# (louder operator signal); the citability verdict always has its own field, and c16=na when there
# is no median.
status="$VERDICT"
[ "$crashed" = 1 ] && status=crash
[ "$NVOID" != 0 ] && echo ">> !! $NVOID VOID row(s) in this experiment — excluded from the median (not data)" >&2
[ "$NSUSP" != 0 ] && echo ">> !! $NSUSP SUSPECT row(s) in this experiment — excluded from the median; adjudicate before citing" >&2
case "$VERDICT" in
  insufficient) echo ">> !! only 1 valid bench — refusing to call it a median (AGENTS.md: don't act on a single run)" >&2 ;;
  no_valid_data) echo ">> !! no valid bench rows — this experiment produced no citable measurement" >&2 ;;
esac

LINE="MEDIAN c16=$MC16 c1=$MC1 n=$NC status=$status cite=$VERDICT valid=$NC/$NROWS void=$NVOID suspect=$NSUSP crash=$NCRASH obj=$OBJ"
[ "$LONE" != na ] && LINE="$LINE lone_$OBJ=$LONE"
echo "$LINE"
case "$VERDICT" in insufficient|no_valid_data) exit 4 ;; esac
exit 0
