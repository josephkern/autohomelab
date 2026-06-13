#!/usr/bin/env bash
# validate.sh <runbook.sh> [suite] — pre-promotion FULL validation of a candidate config: the
# "works" + "good" gates. Serves once, runs smoke (functional), then a FULL lm-eval (quality, no
# LIMIT), tears down, and writes a validation report. Run this on the throughput winner BEFORE
# scripts/promote.sh. Throughput is characterized separately (run_experiment.sh / full sweep).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
SCORES="$(tail -n +2 "$OUT_DIR/accuracy.tsv" 2>/dev/null | awk -F'\t' -v c="$CFG" '$5==c{s=$10} END{print s}')"
[ -z "$SCORES" ] && SCORES="(see accuracy.tsv)"

"$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true

{
  echo "# Validation report — $MODEL"
  echo "- date: $DATE"
  echo "- node: $NODE_FP   config_hash: $CFG"
  echo "- runbook: $(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"
  echo "- backend: $("$REPO_ROOT/backends/vllm/adapter.sh" info 2>/dev/null || echo 'n/a (down)')"
  echo "- **Gate 1 functional (smoke): $smoke_status**"
  echo "- **Gate 2 quality (lm-eval $SUITE): $SCORES**  (eval run: $eval_status)"
  echo "- Gate 3 throughput: see results.tsv / logbook full-sweep"
  echo
  echo "Compare scores to the model card's reference (recovery %); promote only if within ~1%."
} > "$REPORT"

echo >&2; echo ">> smoke=$smoke_status  scores=$SCORES  report -> $(realpath --relative-to="$REPO_ROOT" "$REPORT")" >&2
[ "$smoke_status" = PASS ]
