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
# Prints:  MEDIAN c16=<x> c1=<y> n=<k> status=<ok|serve_fail|smoke_fail|crash>
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

if [ "${RESTART:-1}" = 1 ]; then
  [ -x "$LAUNCHER" ] || { echo "launcher not executable: $LAUNCHER" >&2; exit 1; }
  "$LAUNCHER" >&2 || { echo "MEDIAN c16=na c1=na n=0 status=serve_fail"; exit 1; }
  # Weights load asynchronously; poll the endpoint the benchmark will actually hit.
  waited=0
  until curl -sf -m 5 "$TARGET/v1/models" >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    if [ "$waited" -ge "${READY_TIMEOUT:-300}" ]; then
      echo ">> server never became ready after ${waited}s" >&2
      echo "MEDIAN c16=na c1=na n=0 status=serve_fail"; exit 1
    fi
  done
  echo ">> ready after ${waited}s" >&2
fi

# Gate 1 (functional) before spending benchmark time on a broken config.
if [ "${SKIP_SMOKE:-0}" != 1 ]; then
  "$SCRIPT_DIR/smoke.sh" "$STUB" >&2 || { echo "MEDIAN c16=na c1=na n=0 status=smoke_fail"; exit 1; }
fi

status=ok
for n in $(seq 1 "$N"); do
  echo ">> bench $n/$N" >&2
  if TAG="$TAG" NOTES="exp=$EXP_ID n$n" "$SCRIPT_DIR/bench_llamacpp.sh" "$STUB" "$EXP_SHAPE" >&2; then :; else
    status=crash; echo ">> bench $n crashed/hung — stopping experiment" >&2; break
  fi
  # A crash row is written by bench_llamacpp.sh itself; catch it too (it exits 0 on a logged hang).
  if tail -1 "$TSV" | grep -q $'\tcrash\t'; then
    status=crash; echo ">> bench $n logged a crash row — stopping experiment" >&2; break
  fi
done

read -r MC1 MC16 NC < <(python3 - "$TSV" "$EXP_ID" "$EXP_SHAPE" <<'PY'
import sys, csv, statistics
tsv, exp, shape = sys.argv[1:4]
c1, c16 = [], []
try:
    rows = list(csv.DictReader(open(tsv), delimiter='\t'))
except FileNotFoundError:
    rows = []
for r in rows:
    if exp in (r.get('notes') or '') and (r.get('shape') or '').startswith(shape):
        for col, acc in (('tps_c1', c1), ('tps_c16', c16)):
            try: acc.append(float(r[col]))
            except (ValueError, TypeError): pass
med = lambda x: round(statistics.median(x), 2) if x else 'na'
print(med(c1), med(c16), len(c16))
PY
)

echo "MEDIAN c16=$MC16 c1=$MC1 n=$NC status=$status"
