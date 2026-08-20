#!/usr/bin/env bash
# run_experiment.sh <runbook.sh> — one autoresearch experiment: serve ONCE, bench N times
# (amortizing the load tax), tear down, and report the median c16 (objective) + c1 (sentinel).
#
#   N=3 EXP_SHAPE=chat LEVELS_SET=1,16 MAX_SECONDS=180 scripts/run_experiment.sh <runbook.sh>
#
# Prints a one-line summary and the median to stdout:
#   MEDIAN c16=<x> c1=<y> n=<k> status=<ok|crash|...> cite=<ok|partial|insufficient|no_valid_data> \
#          valid=<k>/<rows> void=<a> suspect=<b> crash=<c> otherlvl=<d> obj=<col> [lone_<col>=<v>]
# void/suspect/crash count rows non-citable AT THE OBJECTIVE LEVEL (contract §3 v1.1: gate on
# the level you cite); `otherlvl` counts rows that ARE in the median but carry a verdict at
# some other level — reported, never blocking, never silent.
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
# Exit codes, in the repo-wide precedence 3 > 4 > 1 > 0 (docs/validity-contract.md §5):
#   0 citable · 1 serve/smoke failure (PRE-measurement: nothing was benched) · 2 the
#   INVOCATION was refused (usage: no runbook, or a STATUS= this loop may not set — nothing
#   was served or written; see the usage_error block below) · 4 the benches
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


# ── USAGE ERRORS GET THEIR OWN RUNG: exit 2 (docs/validity-contract.md §5, v1.3) ──────────────
# This file's own header defines 1 as a PRE-MEASUREMENT failure: the serve or the smoke was
# attempted and it failed. A REJECTED INVOCATION attempted nothing, so reporting it as 1 tells the
# caller a serve was tried — and the old refusals also exited without printing a `MEDIAN` line at
# all, so a caller that parses stdout (every run-queue table does) got silence. 2 is therefore its
# own rung, OUTSIDE the 3 > 4 > 1 > 0 result ladder, which ranks outcomes of work that ran; and
# every exit from here still prints exactly one MEDIAN line.
usage_error() {
  local line
  for line in "$@"; do echo "!! $line" >&2; done
  echo "MEDIAN c16=na c1=na n=0 status=usage_error cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 otherlvl=0 obj=c16"
  exit 2
}

# ── §6/§7 (v1.3): a tuning loop does not write verdicts into the journal ──────────────────────
# `STATUS=keep|discard` used to be the documented way to adjudicate a row at bench time. Neither
# is legal any more, and this script hard-codes `STATUS=measured` for every bench it runs, so an
# operator who sets one is asking for something that will silently not happen:
#   `keep`    is RETIRED (0 of 317 rows ever carried it). A keep verdict is per-CONFIG, decided on
#             the median of N — which is precisely what this script's MEDIAN line reports, and the
#             comparison it needs does not exist yet when a row is written.
#   `discard` is an ORCHESTRATOR adjudication applied to the journal AFTER the fact, carrying
#             `adjudicated@YYYYMMDD who: reason` in `notes` (contract §7). A loop must not
#             self-authorize one — the same reason there is no include-anyway switch here.
case "${STATUS:-}" in
  keep)
    usage_error "STATUS=keep is RETIRED (contract §6, v1.3): a keep verdict is per-config on a" \
                "median of N, not a property of one row — it is this script's MEDIAN line and" \
                "the campaign logbook that record it. Re-run without STATUS." ;;
  discard)
    usage_error "STATUS=discard is an ORCHESTRATOR ADJUDICATION (contract §7), applied to the" \
                "journal after the fact and stamped 'adjudicated@YYYYMMDD who: reason' in notes." \
                "A tuning loop must not self-authorize one. Re-run without STATUS, then" \
                "adjudicate the written rows by hand." ;;
  ""|measured) ;;
  crash|suspect|void)
    usage_error "STATUS='${STATUS}' is COMPUTED, not declared: crash comes from the watchdog and" \
                "suspect/void from the validity floor (contract section 5). Setting it by hand would" \
                "assert an outcome before the run happened. Re-run without STATUS." ;;
  *)
    usage_error "STATUS='${STATUS}' is not in the contract §6 vocabulary" \
                "(measured discard crash suspect void); this script benches as STATUS=measured." ;;
esac

[ "$#" -ge 1 ] || usage_error "usage: run_experiment.sh <runbook.sh>"
RUNBOOK="$1"
[ -f "$RUNBOOK" ] || usage_error "runbook not found: $RUNBOOK"
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
  echo "MEDIAN c16=na c1=na n=0 status=serve_fail cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 otherlvl=0 obj=c16"; exit 1; }

# Gate 1 (functional): cheap smoke before spending benchmark time on a broken config.
if [ "${SKIP_SMOKE:-0}" != 1 ]; then
  "$SCRIPT_DIR/smoke.sh" "$RUNBOOK" || {
    "$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true
    echo "MEDIAN c16=na c1=na n=0 status=smoke_fail cite=no_valid_data valid=0/0 void=0 suspect=0 crash=0 otherlvl=0 obj=c16"; exit 1; }
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

# The bench loop's view (crash) and the journal's view (validity) are separate axes; report the
# worse of the two in `status=` and always publish the counts so nothing is hidden behind one token.
# Two independent axes, both published: `status=` keeps its historical meaning (ok | crash | the
# pre-measurement failures) so existing run-queue tables keep working, and `cite=` carries the new
# citability verdict. A crash is the louder operator signal, so it wins `status=`; the citability
# verdict is never lost because it always has its own field (and c16=na when there is no median).
status="$VERDICT"
[ "$VERDICT" = error ] && status=summarize_fail
[ "$crashed" = 1 ] && status=crash
[ "$NVOID" != 0 ]  && echo ">> !! $NVOID VOID row(s) in this experiment — excluded from the median (not data)" >&2
[ "$NSUSP" != 0 ]  && echo ">> !! $NSUSP SUSPECT row(s) in this experiment — excluded from the median; adjudicate before citing" >&2
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
