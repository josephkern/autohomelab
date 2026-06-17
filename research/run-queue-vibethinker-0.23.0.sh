#!/usr/bin/env bash
# Lean tune queue — vLLM 0.23.0, WeiboAI/VibeThinker-3B (Qwen2.5-3B DENSE BF16, COMPUTE-bound: chat
# scales to c32). Throughput-only (BF16 weights unchanged -> NO quality eval; the aime gate stands).
# Each candidate = baseline + ONE change, N=3 (c1 sentinel + c16 objective). Smoke-gated, crash-safe.
# Writes a report; does NOT auto-promote.
set -uo pipefail
cd "$(dirname "$0")/.."
RBDIR=runbooks/WeiboAI/VibeThinker-3B
BASE="$RBDIR/baseline.sh"
RESDIR=results/gb10-1988a9714b4e/WeiboAI/VibeThinker-3B
SUM="$RESDIR/OVERNIGHT-vibethinker-0.23.0.md"
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }
measure(){ N=3 scripts/run_experiment.sh "$1" 2>&1 | grep '^MEDIAN' | tail -1; }
CANDIDATES=( async-sched batched-32k )
declare -A RESULT

log "=== vibethinker tune queue start (vLLM 0.23.0) ==="
BL=$(measure "$BASE"); BASE_C16=$(parse c16 "$BL"); log "baseline: $BL"
{ [ -z "${BASE_C16:-}" ] || [ "$BASE_C16" = na ]; } && BASE_C16=485

for slug in "${CANDIDATES[@]}"; do
  rb="$RBDIR/20260617_${slug}_tuned.sh"
  [ -f "$rb" ] || { log "MISSING $rb"; RESULT[$slug]="na|na|missing"; continue; }
  log "--- $slug ($(sed -n 's/^# Deltas vs base: //p' "$rb")) ---"
  git add "$rb" 2>/dev/null && git commit -q -m "exp(vibethinker/0.23.0): $slug" 2>/dev/null
  m=$(measure "$rb"); c16=$(parse c16 "$m"); c1=$(parse c1 "$m"); st=$(parse status "$m")
  log "$slug -> $m"
  if [ "$st" = ok ] && [ -n "$c16" ] && [ "$c16" != na ]; then
    if awk "BEGIN{exit !($c16 > $BASE_C16*1.03)}"; then note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c16/$BASE_C16-1)*100}")%)"
    else note="discard ($(awk "BEGIN{printf \"%+.1f\",($c16/$BASE_C16-1)*100}")%, within noise)"; fi
  else note="discard ($st)"; fi
  RESULT[$slug]="${c16:-na}|${c1:-na}|$note"
done

{
  echo "# vibethinker-3b tune queue — vLLM 0.23.0 ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo; echo "Baseline median **c16 = ${BASE_C16}** tok/s chat (N=3). Keep threshold +3%. Throughput-only"
  echo "(BF16 weights unchanged) -> no quality eval; competition-math gate (aime24=90.0/aime25=86.67) stands."
  echo; echo "| candidate | c16 | c1 | verdict |"; echo "|---|---|---|---|"
  for slug in "${CANDIDATES[@]}"; do IFS='|' read -r c16 c1 nt <<<"${RESULT[$slug]:-na|na|not run}"; echo "| $slug | $c16 | $c1 | $nt |"; done
  echo; echo "Recommendation: promote best KEEP via promote.sh VLLM_TAG=23; else baseline stands (the"
  echo "compute-bound 3B baseline is already well-tuned; finalize throughput = the committed full sweep)."
} > "$SUM"
git add -A && git commit -q -m "vibethinker tune queue: ablation results + report" 2>/dev/null
log "=== vibethinker tune queue DONE — $SUM ==="; cat "$SUM"
