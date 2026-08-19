#!/usr/bin/env bash
# validate.sh <runbook.sh> [suite] — pre-promotion FULL validation of a candidate config: the
# "works" + "good" gates. Serves once, runs smoke (functional), then a FULL lm-eval (quality, no
# LIMIT), tears down, and writes a validation report. Run this on the throughput winner BEFORE
# scripts/promote.sh. Throughput is characterized separately (run_experiment.sh / full sweep).
#
# Gate 3 is not RUN here, but it is CHECKED: the report reads back the results.tsv rows for this
# config and reports their measurement validity (docs/validity-contract.md §5/§6). A config whose
# throughput rows are `void`/`suspect` is not validated — "see results.tsv" was how an uncitable
# number reached promotion in the first place.
#
# Exit: 0 all checked gates pass · 1 smoke (Gate 1) failed · 4 Gate-3 rows are not citable.
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
# NOTE: `tail` on a missing accuracy.tsv fails, and under `set -euo pipefail` that killed the whole
# script *before* it wrote a report — a validation run that produced no accuracy row vanished with
# exit 1 and no artifact. Guard the read so the report is always written.
SCORES=""
[ -f "$OUT_DIR/accuracy.tsv" ] && SCORES="$(tail -n +2 "$OUT_DIR/accuracy.tsv" | awk -F'\t' -v c="$CFG" '$5==c{s=$10} END{print s}')"
[ -z "$SCORES" ] && SCORES="(see accuracy.tsv)"

"$SCRIPT_DIR/serve.sh" down >/dev/null 2>&1 || true

# ── Gate 3 read-back: are this config's existing throughput rows citable? ──────
# Prints line 1 = verdict token (ok|invalid|missing), lines 2.. = detail.
set +e
G3="$(python3 - "$OUT_DIR/results.tsv" "$CFG" <<'PY'
import sys, csv
tsv, cfg = sys.argv[1:3]
FATAL = {'no_data', 'over_roofline'}          # docs/validity-contract.md §3
def classify(r):
    st = (r.get('status') or '').strip().lower()
    if st in ('void', 'suspect', 'crash'): return st
    toks = [t for t in (r.get('validity') or '').replace('+', ' ').split() if t and t not in ('ok','na')]
    if any(t in FATAL for t in toks): return 'void'
    if toks: return 'suspect'
    return 'valid'
try:
    rows = [r for r in csv.DictReader(open(tsv), delimiter='\t') if r.get('config_hash') == cfg]
except FileNotFoundError:
    rows = []
if not rows:
    print('missing'); print('no results.tsv throughput rows for config_hash %s — Gate 3 has not been run' % cfg)
    sys.exit(0)
cls = [(r, classify(r)) for r in rows]
n = {k: sum(1 for _, c in cls if c == k) for k in ('valid','suspect','void','crash')}
head = 'rows=%d valid=%d suspect=%d void=%d crash=%d' % (len(rows), n['valid'], n['suspect'], n['void'], n['crash'])
bad = [(r, c) for r, c in cls if c in ('void','suspect')]
print('invalid' if (bad or not n['valid']) else 'ok')
print(head)
for r, c in bad:
    print('  %s %s -> %s (validity=%s req_counts=%s)' % (
        r.get('run_id','?'), r.get('shape','?'), c, r.get('validity','na'), r.get('req_counts','na')))
if not n['valid'] and not bad:
    print('  no VALID row — only crash rows')
PY
)"
set -e
G3_VERDICT="$(printf '%s\n' "$G3" | head -1)"
G3_DETAIL="$(printf '%s\n' "$G3" | tail -n +2)"
case "$G3_VERDICT" in
  ok)      G3_LABEL="PASS (rows citable)" ;;
  invalid) G3_LABEL="FAIL — rows are void/suspect/crash, NOT citable" ;;
  *)       G3_LABEL="NOT RUN (promote.sh will refuse until a valid throughput row exists)" ;;
esac

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
[ "$smoke_status" = PASS ] || exit 1
[ "$G3_VERDICT" = invalid ] && exit 4
exit 0
