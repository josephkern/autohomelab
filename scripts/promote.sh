#!/usr/bin/env bash
# promote.sh <winning_runbook.sh> ["result note"] — when a model's tuning campaign is complete,
# promote the chosen config to a canonical `_final.sh`. The `_tuned.sh` experiment artifacts are
# left intact (project record); the `_final.sh` is what you actually serve.
#
# Runbook file types in a model dir:
#   baseline.sh         generated start (gen_baseline.py)
#   *_tuned.sh          experiment variants (kept as artifacts)
#   *_final.sh          promoted campaign winner — the canonical config
#
# ── MEASUREMENT-VALIDITY GATE (docs/validity-contract.md §5/§6) ───────────────
# Promotion is the act of citing a measurement forever, so it REFUSES to run when the benchmark
# rows supporting this config (results.tsv rows with the same config_hash) are `void` (not data) or
# `suspect` (measured, but an invariant questions it) — and equally when there are NO supporting
# rows at all. A promotion with nothing behind it is the same defect as one behind a bad number.
#
# OVERRIDE — for the case where a human has ADJUDICATED the flagged rows:
#
#   AHL_PROMOTE_OVERRIDE="20260819 jk: c32 low_sample only; objective is c16, unaffected" \
#     scripts/promote.sh <runbook.sh> "note"
#
# The variable must carry a real justification (>= 12 chars; bare 1/y/yes/true/force are REJECTED —
# an override is an argument, not a flag). It is not a bypass, it is a signature: the promoted
# `_final.sh` records the justification, the adjudicator, the date, and the exact offending
# run_ids in its header AND in a greppable `AHL_PROMOTION_OVERRIDE=` assignment, so a config
# promoted over a flagged measurement is traceable forever:
#
#   grep -l AHL_PROMOTION_OVERRIDE runbooks/*/*/*_final.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${1:?usage: promote.sh <winning_runbook.sh> [\"result note\"]}"
NOTE="${2:-}"
[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

# Derive the canonical final name: VLLM-<minor>-<HFORG>_<BASEMODEL>_<QUANT>_final.sh
MODEL=""; VLLM_IMAGE=""
# shellcheck disable=SC1090
source "$SRC"; : "${MODEL:?runbook must set MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; LEAF="${MODEL##*/}"
# split a known quant suffix off the model leaf (so NVFP4 is its own token)
QUANT=""; BASE="$LEAF"
for q in NVFP4 MXFP4 FP8 FP4 INT8 INT4 AWQ GPTQ W8A8 W4A16; do
  case "$LEAF" in *-"$q") QUANT="$q"; BASE="${LEAF%-$q}"; break ;; esac
done
# vLLM minor version from the runbook's image comment (e.g. "v0.22.0" -> 22), override with VLLM_TAG
# NOTE: AGENTS.md tracks an open bug here (this greps the FIRST vX.Y.Z in the file, so a migration
# comment can win). Deliberately left exactly as found — fixing it is not this change's job.
VV="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$SRC" | head -1 | sed 's/^v//' || true)"
VMINOR="${VLLM_TAG:-$(printf '%s' "$VV" | cut -d. -f2)}"; : "${VMINOR:=XX}"
NAME="VLLM-${VMINOR}-${ORG}_${BASE}"; [ -n "$QUANT" ] && NAME="${NAME}_${QUANT}"
OUT="$(dirname "$SRC")/${NAME}_final.sh"
[ -e "$OUT" ] && { echo "already exists: $OUT (remove it to re-promote)" >&2; exit 1; }

# ── Validity gate ─────────────────────────────────────────────────────────────
CFG="$(sha256sum "$SRC" | cut -c1-8)"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename || true)"
TSV="$REPO_ROOT/results/${NODE_FP:-_}/$ORG/${MODEL##*/}/results.tsv"

set +e
GATE="$(python3 - "$TSV" "$CFG" <<'PY'
import sys, csv
tsv, cfg = sys.argv[1:3]
# docs/validity-contract.md §3/§6. `status` is the adjudicated verdict, `validity` the evidence;
# re-derive from the tokens too, so a row that recorded a verdict but was not downgraded still blocks.
FATAL = {'no_data', 'over_roofline'}

def classify(r):
    st = (r.get('status') or '').strip().lower()
    if st in ('void', 'suspect', 'crash'):
        return st
    toks = [t for t in (r.get('validity') or '').replace('+', ' ').split()
            if t and t not in ('ok', 'na')]
    if any(t in FATAL for t in toks):
        return 'void'
    if toks:
        return 'suspect'
    return 'valid'

try:
    rows = [r for r in csv.DictReader(open(tsv), delimiter='\t') if r.get('config_hash') == cfg]
except FileNotFoundError:
    print('blocked'); print('no results.tsv for this model at %s' % tsv); sys.exit(1)
if not rows:
    print('blocked')
    print('NO benchmark rows in results.tsv for config_hash %s — nothing supports this promotion.' % cfg)
    print('(a promotion with no supporting measurement is the same defect as one behind a bad number)')
    sys.exit(1)
cls = [(r, classify(r)) for r in rows]
counts = {k: sum(1 for _, c in cls if c == k) for k in ('valid', 'suspect', 'void', 'crash')}
bad = [(r, c) for r, c in cls if c in ('void', 'suspect')]
summary = 'rows=%d valid=%d suspect=%d void=%d crash=%d' % (
    len(rows), counts['valid'], counts['suspect'], counts['void'], counts['crash'])
detail = ['  %-24s %-8s %-7s validity=%s req_counts=%s' % (
    r.get('run_id', '?'), r.get('shape', '?'), c, r.get('validity', 'na'), r.get('req_counts', 'na'))
    for r, c in bad]
if bad:
    print('blocked'); print(summary)
    print('%d supporting row(s) are not citable:' % len(bad)); print('\n'.join(detail))
    print('ids=' + ','.join(r.get('run_id', '?') for r, _ in bad))
    sys.exit(1)
if not counts['valid']:
    print('blocked'); print(summary)
    print('no VALID supporting row (only crash rows) — there is no measurement to promote on')
    sys.exit(1)
print('ok'); print(summary)
PY
)"
GATE_RC=$?
set -e
GATE_VERDICT="$(printf '%s\n' "$GATE" | head -1)"
GATE_DETAIL="$(printf '%s\n' "$GATE" | tail -n +2)"
GATE_IDS="$(printf '%s\n' "$GATE" | sed -n 's/^ids=//p')"

OVERRIDE="${AHL_PROMOTE_OVERRIDE:-}"
if [ "$GATE_RC" != 0 ] || [ "$GATE_VERDICT" != ok ]; then
  echo "!! VALIDITY GATE FAILED for $(basename "$SRC") (config_hash $CFG)" >&2
  printf '%s\n' "$GATE_DETAIL" >&2
  if [ -z "$OVERRIDE" ]; then
    cat >&2 <<EOM
!! REFUSING to promote. Fix the measurement (re-bench with a stage budget that drains enough
!! requests — see AGENTS.md "MAX_SECONDS=180 is NOT universal"), or, if a human has ADJUDICATED
!! these rows, re-run with a written justification:
!!   AHL_PROMOTE_OVERRIDE="<YYYYMMDD who>: why these rows do not invalidate the promotion" \\
!!     scripts/promote.sh $SRC "note"
EOM
    exit 4
  fi
  case "${OVERRIDE,,}" in
    1|y|yes|true|force|override|ok) echo "!! AHL_PROMOTE_OVERRIDE must be a JUSTIFICATION, not a flag (got: '$OVERRIDE')" >&2; exit 4 ;;
  esac
  if [ "${#OVERRIDE}" -lt 12 ]; then
    echo "!! AHL_PROMOTE_OVERRIDE too short (${#OVERRIDE} chars) — write why the flagged rows were adjudicated" >&2
    exit 4
  fi
  echo "!! OVERRIDDEN by AHL_PROMOTE_OVERRIDE — recording the adjudication in the promoted artifact" >&2
else
  echo ">> validity gate: ok ($GATE_DETAIL)" >&2
  OVERRIDE=""   # a clean gate never records an override, even if the var was set
fi

cp "$SRC" "$OUT"
DATE="$(date -u +%Y-%m-%d)"
python3 - "$OUT" "$SRC" "$DATE" "$NOTE" "$CFG" "$GATE_DETAIL" "$OVERRIDE" "$GATE_IDS" "${USER:-unknown}" <<'PY'
import sys
out, src, date, note, cfg, gate, override, ids, who = sys.argv[1:10]

def clean(s):           # one line, no quote-breaking — this text is embedded in a shell assignment
    return ' '.join(s.replace('"', "'").split())

banner = [
    f"# FINAL (campaign-selected) — promoted from {src} on {date}.\n",
    (f"# Result: {note}\n" if note else "# Result: <fill in: best metric vs baseline>\n"),
    "# Canonical config to serve. The *_tuned.sh experiment artifacts are kept intact as record.\n",
    f"# Supporting benchmark rows (results.tsv config_hash={cfg}): {clean(gate.splitlines()[0]) if gate.strip() else 'na'}\n",
]
if override:
    banner += [
        "#\n",
        "# !! PROMOTED OVER A FAILED MEASUREMENT-VALIDITY GATE (docs/validity-contract.md).\n",
        "# !! The supporting benchmark rows were flagged void/suspect and a human adjudicated them.\n",
        f"# !! adjudicated by : {clean(who)} on {date}\n",
        f"# !! justification  : {clean(override)}\n",
    ]
    for line in gate.splitlines()[1:]:
        if line.startswith('ids='):
            continue
        banner.append(f"# !! gate           : {clean(line)}\n")
    banner += [
        "# !! Numbers cited for this config MUST carry this caveat.\n",
        "#\n",
        "# Greppable marker — presence of AHL_PROMOTION_OVERRIDE means this promotion was NOT\n",
        "# supported by a clean measurement. It is inert at serve time (nothing reads it).\n",
        f'AHL_PROMOTION_OVERRIDE="{clean(override)}"\n',
        f'AHL_PROMOTION_OVERRIDE_ROWS="{clean(ids) or "na"}"\n',
        f'AHL_PROMOTION_OVERRIDE_BY="{clean(who)} {date}"\n',
    ]
lines = open(out).read().splitlines(keepends=True)
# insert after shebang
if lines and lines[0].startswith("#!"):
    lines = lines[:1] + banner + lines[1:]
else:
    lines = banner + lines
open(out, "w").writelines(lines)
PY
chmod +x "$OUT"
echo "$OUT"
