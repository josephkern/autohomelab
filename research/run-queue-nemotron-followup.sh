#!/usr/bin/env bash
# Follow-up runs after the main nemotron 6-queue: the user-requested trust-remote-code candidate
# and the mtp+cutlass STACK of the two queue winners. N=3 c1/c16, smoke-gated, crash-safe.
# Appends a section to OVERNIGHT-nemotron-0.23.0.md. Does NOT auto-promote.
set -uo pipefail
cd "$(dirname "$0")/.."
RBDIR=runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
RESDIR=results/gb10-1988a9714b4e/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
SUM="$RESDIR/OVERNIGHT-nemotron-0.23.0.md"
BASE_C16=75.54   # this-session baseline
MTP_BEST=92.77   # current best (mtp-n1 solo) — combo must beat this to be worth stacking
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }
measure(){ N=3 scripts/run_experiment.sh "$1" 2>&1 | grep '^MEDIAN' | tail -1; }
declare -A RESULT

run(){ # slug | ref_value | ref_label
  local slug="$1" ref="$2" lbl="$3"
  local rb="$RBDIR/20260616_${slug}_tuned.sh"
  [ -f "$rb" ] || { log "MISSING $rb"; RESULT[$slug]="na|na|missing|absent"; return; }
  log "--- $slug ($(sed -n 's/^# Deltas vs base: //p' "$rb")) ---"
  git add "$rb" 2>/dev/null && git commit -q -m "exp(nemotron/0.23.0): $slug" 2>/dev/null
  local m c16 c1 st; m=$(measure "$rb"); c16=$(parse c16 "$m"); c1=$(parse c1 "$m"); st=$(parse status "$m")
  log "$slug -> $m"
  local note="vs $lbl $ref"
  if [ "$st" = ok ] && [ -n "$c16" ] && [ "$c16" != na ]; then
    if awk "BEGIN{exit !($c16 > $ref*1.03)}"; then
      note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c16/$ref-1)*100}")% vs $lbl)"
    else
      note="discard ($(awk "BEGIN{printf \"%+.1f\",($c16/$ref-1)*100}")% vs $lbl)"
    fi
  else note="discard ($st)"; fi
  RESULT[$slug]="${c16:-na}|${c1:-na}|${st:-na}|$note"
}

log "=== nemotron follow-up queue start ==="
run trust-remote-code "$BASE_C16" "base"
run mtp-cutlass "$MTP_BEST" "mtp-best"

{
  echo
  echo "## Follow-up runs ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "| candidate | c16 | c1 | status | verdict |"
  echo "|---|---|---|---|---|"
  for slug in trust-remote-code mtp-cutlass; do
    IFS='|' read -r c16 c1 st nt <<<"${RESULT[$slug]:-na|na|na|not run}"
    echo "| $slug | $c16 | $c1 | $st | $nt |"
  done
} >> "$SUM"
git add -A && git commit -q -m "nemotron follow-up: trust-remote-code + mtp-cutlass stack" 2>/dev/null
log "=== follow-up DONE ==="
sed -n '/## Follow-up runs/,$p' "$SUM"
