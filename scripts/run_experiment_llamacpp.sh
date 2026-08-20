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
#          valid=<k>/<rows> void=<a> suspect=<b> crash=<c> otherlvl=<d> obj=<col> [lone_<col>=<v>]
# void/suspect/crash count rows non-citable AT THE OBJECTIVE LEVEL (contract §3 v1.1: gate on
# the level you cite); `otherlvl` counts rows that ARE in the median but carry a verdict at
# some other level — reported, never blocking, never silent.
#
# ── WHY THIS LOOP NEVER WRITES `keep` ─────────────────────────────────────────
# Same adjudication as run_experiment.sh (20260820), whose header carries the full argument: the
# row `status` column is a VALIDITY state, not a verdict. `keep` had 0 of 315 rows because the
# keep/discard decision is known only AFTER the median, is about a config rather than a row, and
# would sit in the same column the validity layer overwrites. The affirmative keep verdict is the
# promoted artifact (for a host backend, the launcher with the winning defaults) plus logbook.md.
# bench_llamacpp.sh does not even read $STATUS — the guard below exists so both runners answer a
# caller identically, and so this can never quietly become a verdict channel later.
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
# Exit codes, in the repo-wide precedence 3 > 4 > 1 > 0 (docs/validity-contract.md §5):
#   0 citable · 1 serve/smoke failure (PRE-measurement: nothing was benched) · 4 the benches
#   ran but the result is not citable — too few valid rows, or the summarizer itself failed
#   (`cite=error`, and the rows are still in results.tsv). A summarizer failure is NEVER 1:
#   conflating it with "the serve failed" is how a caller concluded nothing had been measured.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Charter rule 4: python via uv when available. citability.py is stdlib-only, so a bare python3
# is a correct fallback (these scripts previously called `python3` unconditionally).
ahl_py() {
  if [ -n "${AHL_PYTHON:-}" ]; then
    # shellcheck disable=SC2086
    $AHL_PYTHON "$@"
  elif command -v uv >/dev/null 2>&1; then
    uv run --project "$REPO_ROOT" --quiet python "$@"
  else
    python3 "$@"
  fi
}

STUB="${1:?usage: TAG=<slug> run_experiment_llamacpp.sh <runbook-stub.sh>}"
[ -f "$STUB" ] || { echo "stub not found: $STUB" >&2; exit 1; }
# See "WHY THIS LOOP NEVER WRITES `keep`" above. Refuse, don't silently ignore.
case "${STATUS:-}" in
  keep|discard)
    {
      echo "!! STATUS=$STATUS is a VERDICT, not a row state, and this loop will not write one."
      echo "!! A row's status is its VALIDITY (measured|suspect|void|crash) — decided by the"
      echo "!! invariants in scripts/lib/validity.py, not by the caller's opinion of the result."
      echo "!! The keep/discard decision is made AFTER the median (tune_status.py) and recorded"
      echo "!! where it is durable and correctly grained: the campaign logbook.md, and — for a"
      echo "!! keep — the promoted launcher whose defaults are the winning config."
    } >&2
    exit 1 ;;
esac
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

FAILLINE="cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 otherlvl=0 obj=c16"
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

# Median over this experiment's rows (tagged exp=$EXP_ID), for the objective shape. The rule
# lives in scripts/citability.py (`median`) — ONE implementation, shared with the vLLM and
# llama.cpp runners and with promote.sh's gate, because five hand-copied classifiers is exactly
# how `'no_data@c16' in {'no_data', 'over_roofline'}` came to be False in all five.
#
# SUMMARIZER FAILURE IS NOT A SERVE FAILURE (defect #5). `read -r ... < <(python ...)` is a simple
# command: under `set -e` a failing summarizer killed the script with exit 1 and NO `MEDIAN` line.
# Exit 1 is documented as a PRE-measurement serve/smoke failure, so the caller concluded nothing
# had been benched while three good rows sat in results.tsv. The read is now guarded: a summarizer
# failure still prints a MEDIAN line, marked `cite=error status=summarize_fail`, and exits 4
# ("the rows were written, they are just not summarized") — never 1.
SUMMARIZE_RC=0
SUMMARY_OUT="$(ahl_py "$SCRIPT_DIR/citability.py" median \
                 --tsv "$TSV" --exp "$EXP_ID" --shape "$EXP_SHAPE" --level 16)" || SUMMARIZE_RC=$?
if [ "$SUMMARIZE_RC" = 0 ] && [ -n "$SUMMARY_OUT" ]; then
  read -r MC1 MC16 NC NVOID NSUSP NCRASH NROWS OBJ LONE VERDICT NOTHER <<<"$SUMMARY_OUT" || SUMMARIZE_RC=1
fi
if [ "$SUMMARIZE_RC" != 0 ] || [ -z "${VERDICT:-}" ]; then
  echo ">> !! the median summarizer FAILED (rc=$SUMMARIZE_RC) — the bench rows ARE in $TSV; only" >&2
  echo ">> !! the summary is missing. This is NOT a serve/smoke failure. Re-run the summarizer:" >&2
  echo ">> !!   scripts/citability.py median --tsv $TSV --exp $EXP_ID --shape $EXP_SHAPE" >&2
  MC1=na; MC16=na; NC=0; NVOID=0; NSUSP=0; NCRASH=0; NROWS=0; OBJ=c16; LONE=na
  VERDICT=error; NOTHER=0
fi

# `status=` keeps its historical meaning (ok | crash | pre-measurement failure) so existing
# run-queue tables keep working; `cite=` carries the new citability verdict. A crash wins `status=`
# (louder operator signal); the citability verdict always has its own field, and c16=na when there
# is no median.
status="$VERDICT"
[ "$VERDICT" = error ] && status=summarize_fail
[ "$crashed" = 1 ] && status=crash
[ "$NVOID" != 0 ] && echo ">> !! $NVOID VOID row(s) in this experiment — excluded from the median (not data)" >&2
[ "$NSUSP" != 0 ] && echo ">> !! $NSUSP SUSPECT row(s) in this experiment — excluded from the median; adjudicate before citing" >&2
case "$VERDICT" in
  insufficient) echo ">> !! only 1 valid bench — refusing to call it a median (AGENTS.md: don't act on a single run)" >&2 ;;
  no_valid_data) echo ">> !! no valid bench rows — this experiment produced no citable measurement" >&2 ;;
esac
# Rows citable for the objective that are nonetheless flagged at ANOTHER level (contract §3 v1.1:
# gate on the level you cite, report the rest). Never silent, never blocking.
[ "${NOTHER:-0}" != 0 ] && echo ">> !! $NOTHER row(s) in the median are flagged at another level (not at $OBJ) — see results.tsv validity" >&2

LINE="MEDIAN c16=$MC16 c1=$MC1 n=$NC status=$status cite=$VERDICT valid=$NC/$NROWS void=$NVOID suspect=$NSUSP crash=$NCRASH otherlvl=$NOTHER obj=$OBJ"
[ "$LONE" != na ] && LINE="$LINE lone_$OBJ=$LONE"
echo "$LINE"
case "$VERDICT" in insufficient|no_valid_data|error) exit 4 ;; esac
exit 0
