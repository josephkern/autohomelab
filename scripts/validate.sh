#!/usr/bin/env bash
# validate.sh <runbook.sh> [suite] — pre-promotion FULL validation of a candidate config: the
# "works" + "good" gates. Serves once, runs smoke (functional), then a FULL lm-eval (quality, no
# LIMIT), tears down, and writes a validation report. Run this on the throughput winner BEFORE
# scripts/promote.sh. Throughput is characterized separately (run_experiment.sh / full sweep).
#
# Gate 3 is not RUN here, but it is CHECKED: the report reads back the results.tsv rows for this
# config and reports their measurement validity (docs/validity-contract.md §3/§5/§6). A config whose
# throughput rows are not citable is not validated — "see results.tsv" was how an uncitable number
# reached promotion in the first place. The check is THE SAME CALL promote.sh makes
# (`scripts/citability.py gate`), scoped to the objective it will cite (chat c16 by default), so
# this report can never disagree with the gate it is supposed to predict.
#
# Gate 2 is CHECKED too, not just run (docs/validity-contract.md A9). eval.sh now scores the
# lm-eval bundle it produced -- a non-finite score, a score over fewer samples than were
# requested, or no score at all makes the row non-citable and eval.sh exits 4. A validation whose
# quality number is `nan` is not a validation, so that is a FAIL here, with the row's `validity`,
# `status`, `samples` and `conc` printed in the report.
#
# Exit codes follow the repo-wide precedence 3 (crash) > 4 (not citable) > 1 (gate failure) > 0.
# A failed smoke no longer HIDES a non-citable Gate 2 or Gate 3: all are reported and 4 wins.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Charter rule 4: prefer uv; citability.py is stdlib-only so python3 is a correct fallback.
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
RUNBOOK="${1:?usage: validate.sh <runbook.sh> [general|coder|auto]}"
SUITE="${2:-auto}"
[ -f "$RUNBOOK" ] || { echo "not found: $RUNBOOK" >&2; exit 1; }

MODEL=""; SERVED_NAME=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"
CFG="$(sha256sum "$RUNBOOK" | cut -c1-8)"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"
REPORT="$OUT_DIR/VALIDATION-${CFG}.md"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ">> validating $(realpath --relative-to="$REPO_ROOT" "$RUNBOOK") (cfg $CFG)" >&2
"$SCRIPT_DIR/serve.sh" "$RUNBOOK" >/dev/null 2>"$REPO_ROOT/.ahl_validate_serve.log" || {
  echo "serve failed; see .ahl_validate_serve.log" >&2; exit 1; }

smoke_status=PASS
"$SCRIPT_DIR/smoke.sh" "$RUNBOOK" || smoke_status=FAIL

# Full quality eval (no LIMIT). Don't abort on eval error - record what we got. eval.sh's exit
# code is a VERDICT now: 3 the harness was killed, 4 the row is written but the score is not a
# measurement, 1 some other failure, 0 citable.
EVAL_SINCE="$(date -u +%Y%m%d-%H%M%S)"
eval_rc=0
"$SCRIPT_DIR/eval.sh" "$RUNBOOK" "$SUITE" || eval_rc=$?
case "$eval_rc" in
  0) eval_status=ok ;;
  3) eval_status=crash ;;
  4) eval_status=invalid ;;
  *) eval_status=error ;;
esac
# NOTE: `tail` on a missing accuracy.tsv fails, and under `set -euo pipefail` that killed the whole
# script *before* it wrote a report - a validation run that produced no accuracy row vanished with
# exit 1 and no artifact. Guard the read so the report is always written.
#
# Read back THIS run's row (run_id >= EVAL_SINCE) for this config: the scores plus the columns
# that say whether the score may be quoted. Column order is fixed by eval.sh's 16-column header
# (contract A9): $1 run_id, $5 config_hash, $10 scores, $13 conc, $14 samples, $15 validity,
# $16 status. The long-standing $5/$10 read still works because the new columns were APPENDED --
# which is why they were appended.
SCORES=""; ACC_CONC=na; ACC_SAMPLES=na; ACC_VALIDITY=na; ACC_STATUS=na; ACC_FOUND=0
if [ -f "$OUT_DIR/accuracy.tsv" ]; then
  ACC_LINE="$(tail -n +2 "$OUT_DIR/accuracy.tsv" \
    | awk -F'\t' -v c="$CFG" -v since="$EVAL_SINCE" \
        '$5==c && $1>=since {s=$10; cc=($13==""?"na":$13); sm=($14==""?"na":$14); v=($15==""?"na":$15); st=($16==""?"na":$16)}
         END{ if (s!="") printf "%s\t%s\t%s\t%s\t%s", s, cc, sm, v, st }')"
  [ -n "$ACC_LINE" ] && { ACC_FOUND=1; IFS=$'\t' read -r SCORES ACC_CONC ACC_SAMPLES ACC_VALIDITY ACC_STATUS <<<"$ACC_LINE"; }
fi
[ -z "$SCORES" ] && SCORES="(see accuracy.tsv)"

# Gate 2 citability, from TWO independent readings: eval.sh's exit code, and the row it wrote.
# Either one saying "not citable" is enough. When a row for this run exists its `validity` decides
# and `na` is never `ok` (contract A5), so a row with no verdict fails CLOSED. When NO row exists
# the exit code decides alone -- eval.sh always writes a row and already fails closed when it
# cannot produce a verdict, so a missing row means eval.sh did not run at all, which its exit code
# is the authority on. This second reading is defence in depth, not the primary gate.
G2_VERDICT=ok
case "$eval_status" in
  crash)   G2_VERDICT=crash ;;
  invalid) G2_VERDICT=invalid ;;
esac
if [ "$G2_VERDICT" = ok ] && [ "$ACC_FOUND" = 1 ]; then
  [ "$ACC_VALIDITY" = ok ] || G2_VERDICT=invalid
  case "$ACC_STATUS" in void|suspect|crash) G2_VERDICT=invalid ;; esac
fi
if [ "$G2_VERDICT" = ok ] && [ "$eval_status" != ok ]; then G2_VERDICT=error; fi
G2_LABEL="PASS (citable)"
case "$G2_VERDICT" in
  invalid) G2_LABEL="FAIL - the score is NOT a measurement, do not quote or promote on it" ;;
  crash)   G2_LABEL="CRASH - the eval harness was killed" ;;
  error)   G2_LABEL="ERROR - lm-eval failed (eval_status=$eval_status)" ;;
esac

"$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true

# ── Gate 3 read-back: are this config's existing throughput rows citable? ──────
# citability.py gate prints line 1 = ok|blocked, line 2 = summary, then detail + the id lines.
set +e
G3="$(ahl_py "$SCRIPT_DIR/citability.py" gate \
        --tsv "$OUT_DIR/results.tsv" --cfg "$CFG" \
        --shape "${AHL_PROMOTE_SHAPE-chat}" --level "${AHL_PROMOTE_LEVEL-16}")"
set -e
G3_RAW="$(printf '%s\n' "$G3" | head -1)"
G3_DETAIL="$(printf '%s\n' "$G3" | tail -n +2 | grep -v '^ids=' | grep -v '^warnids=' || true)"
# "no rows at all" is NOT the same failure as "the rows are bad": Gate 3 simply has not been run.
if [ "$G3_RAW" = ok ]; then
  G3_VERDICT=ok;      G3_LABEL="PASS (the objective's rows are citable)"
elif printf '%s\n' "$G3_DETAIL" | grep -q 'NO benchmark rows\|no results.tsv'; then
  G3_VERDICT=missing; G3_LABEL="NOT RUN (promote.sh will refuse until a valid throughput row exists)"
else
  G3_VERDICT=invalid; G3_LABEL="FAIL — the objective's rows are void/suspect/crash, NOT citable"
fi

VERDICT=PASS
[ "$smoke_status" = PASS ] || VERDICT=FAIL
[ "$G2_VERDICT" = ok ] || VERDICT=FAIL
[ "$G3_VERDICT" = invalid ] && VERDICT=FAIL

{
  echo "# Validation report — $MODEL"
  echo "- date: $DATE"
  echo "- node: $NODE_FP   config_hash: $CFG"
  echo "- runbook: $(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
  echo "- backend: $("$REPO_ROOT/backends/vllm/adapter.sh" info 2>/dev/null || echo 'n/a (down)')"
  echo "- **VALIDATION VERDICT: $VERDICT**$([ "$G3_VERDICT" = missing ] && echo '  (Gates 1+2 only — Gate 3 not run yet)' || true)"
  echo "- **Gate 1 functional (smoke): $smoke_status**"
  echo "- **Gate 2 quality (lm-eval $SUITE): $G2_LABEL**"
  echo "    - scores: \`$SCORES\`   samples (effective/requested): $ACC_SAMPLES   conc: $ACC_CONC"
  echo "    - status: $ACC_STATUS   validity: $ACC_VALIDITY   (eval run: $eval_status)"
  [ "$ACC_FOUND" = 1 ] || echo "    - NOTE: no accuracy.tsv row from this run; the verdict is eval.sh's exit code alone"
  if [ "$G2_VERDICT" = invalid ]; then
    echo
    echo "Gate 2 measurement-validity failure (docs/validity-contract.md A9): this score is not a"
    echo "measurement. A non-finite value, a score computed over fewer samples than were requested,"
    echo "no score at all, or a score of exactly 0.0 (check the serve emitted tokens - AGENTS.md"
    echo "records NemotronH generating none under enable_thinking=false). Do NOT promote on it."
  fi
  echo "- **Gate 3 throughput (read back from results.tsv): $G3_LABEL**"
  printf '%s\n' "$G3_DETAIL" | sed 's/^/    /'
  if [ "$G3_VERDICT" = invalid ]; then
    echo
    echo "Gate 3 measurement-validity failure (docs/validity-contract.md): the rows above are not"
    echo "data. Do NOT promote on them — re-bench with a per-level stage budget that drains enough"
    echo 'requests (AGENTS.md: "MAX_SECONDS=180 is NOT universal"; want >=20 successful per level).'
  fi
  echo
  echo "Compare scores to the model card's reference (recovery %); promote only if within ~1%."
} > "$REPORT"

echo >&2; echo ">> verdict=$VERDICT smoke=$smoke_status gate2=$G2_VERDICT gate3=$G3_VERDICT scores=$SCORES  report -> $(realpath --relative-to="$REPO_ROOT" "$REPORT")" >&2

# Exit-code precedence, repo-wide (docs/validity-contract.md §5): 3 crash > 4 not citable >
# 1 gate failure > 0. `exit 1` used to come FIRST, so a config that failed smoke AND had
# uncitable throughput rows reported only the smoke failure — the louder signal masked the
# quieter, more corrosive one. 4 now wins, and both are in the report either way.
# Gate 2 rides the same ladder: "the quality score is not a measurement" is exactly as corrosive
# as the throughput equivalent, and until now it could not be reported at all.
rc=0
[ "$smoke_status" = PASS ] || rc=1
[ "$G2_VERDICT" = error ] && rc=1
{ [ "$G2_VERDICT" = invalid ] || [ "$G3_VERDICT" = invalid ]; } && rc=4
[ "$G2_VERDICT" = crash ] && rc=3
exit "$rc"
