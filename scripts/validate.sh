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
# Exit codes follow the repo-wide precedence 3 (crash) > 4 (not citable) > 1 (gate failure) > 0.
# A failed smoke no longer HIDES a non-citable Gate 3: both are reported and 4 wins.
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

# Full quality eval (no LIMIT). Don't abort on eval error — record what we got.
eval_status=ok
"$SCRIPT_DIR/eval.sh" "$RUNBOOK" "$SUITE" || eval_status=error
# NOTE: `tail` on a missing accuracy.tsv fails, and under `set -euo pipefail` that killed the whole
# script *before* it wrote a report — a validation run that produced no accuracy row vanished with
# exit 1 and no artifact. Guard the read so the report is always written.
SCORES=""
[ -f "$OUT_DIR/accuracy.tsv" ] && SCORES="$(tail -n +2 "$OUT_DIR/accuracy.tsv" | awk -F'\t' -v c="$CFG" '$5==c{s=$10} END{print s}')"
[ -z "$SCORES" ] && SCORES="(see accuracy.tsv)"

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
[ "$G3_VERDICT" = invalid ] && VERDICT=FAIL

{
  echo "# Validation report — $MODEL"
  echo "- date: $DATE"
  echo "- node: $NODE_FP   config_hash: $CFG"
  echo "- runbook: $(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
  echo "- backend: $("$REPO_ROOT/backends/vllm/adapter.sh" info 2>/dev/null || echo 'n/a (down)')"
  echo "- **VALIDATION VERDICT: $VERDICT**$([ "$G3_VERDICT" = missing ] && echo '  (Gates 1+2 only — Gate 3 not run yet)' || true)"
  echo "- **Gate 1 functional (smoke): $smoke_status**"
  echo "- **Gate 2 quality (lm-eval $SUITE): $SCORES**  (eval run: $eval_status)"
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

echo >&2; echo ">> verdict=$VERDICT smoke=$smoke_status gate3=$G3_VERDICT scores=$SCORES  report -> $(realpath --relative-to="$REPO_ROOT" "$REPORT")" >&2

# Exit-code precedence, repo-wide (docs/validity-contract.md §5): 3 crash > 4 not citable >
# 1 gate failure > 0. `exit 1` used to come FIRST, so a config that failed smoke AND had
# uncitable throughput rows reported only the smoke failure — the louder signal masked the
# quieter, more corrosive one. 4 now wins, and both are in the report either way.
rc=0
[ "$smoke_status" = PASS ] || rc=1
[ "$G3_VERDICT" = invalid ] && rc=4
exit "$rc"
