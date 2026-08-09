#!/usr/bin/env bash
# DS4 round 4 — antirez/ds4 "DwarfStar" DeepSeek-V4-Flash q2-imatrix on GB10 (20260809).
#
# WHY THIS ROUND: upstream landed 32 commits since our round-3 pin (b030961), including
#   0e89a0e "dspark: commit accepted verifier state directly"  (ds4.c +135)
#   84cc882 "rocm: enable DSpark speculative decoding"          (DSpark maturing across backends)
#   e9ded97/8a703b6 server: cancel work on client disconnect    (GuideLLM cancels at stage end)
#   0ead8a8/3196149 server: tool-call recovery + OpenAI schema spelling  (Gate 1 surface)
# and a NEW tuning axis that did not exist when round 3 DISCARDed DSpark (-17% chat / -18% code):
#   --dspark-confidence F   prunes draft suffixes unlikely to repay verification. CUDA default 0.7.
#
# OBJECTIVE = c1 (ds4 is single-session; LEVELS_SET defaults to 1 in bench_ds4.sh), N=3 median,
# greedy (TEMP=0 — DSpark only engages on greedy requests). Reference: round 3 c1 median 19.63.
#
# QUALITY IS NOT INHERITED. Upstream README: "A long greedy DSpark run may therefore diverge from
# a run without DSpark after an otherwise valid accepted block." So unlike vLLM MTP (greedy-
# lossless), a DSpark keep MUST clear Gate 2 on its own — this script flags it, and gsm8k is run
# by hand on any winner before promotion.
#
#   BASE_C1=<this-session target-only median> research/run-queue-ds4-round4.sh [slug ...]
set -uo pipefail   # NOT -e: keep going past a failed candidate
cd "$(dirname "$0")/.."

LAUNCHER=launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh
STUB=launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.smoke-runbook.sh
RESDIR="results/gb10-1988a9714b4e/antirez/DeepSeek-V4-Flash"
SUM="$RESDIR/ROUND4-dspark.md"
TARGET="http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}"
BASE_C1="${BASE_C1:?set BASE_C1=<this-session target-only median c1>}"
N="${N:-3}"
export LEVELS_SET="${LEVELS_SET:-1}" MAX_SECONDS="${MAX_SECONDS:-180}"

log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
declare -A RESULT HYP

# run <slug> <hypothesis> <env assignments...>
run(){
  local slug="$1" hyp="$2"; shift 2
  log "--- $slug ($hyp) [$*] ---"
  HYP[$slug]="$hyp"

  if ! env "$@" "$LAUNCHER" >&2; then
    log "$slug: launcher failed"; RESULT[$slug]="na|serve_fail|launcher error"; return
  fi
  # ~87 GiB of weights: allow a long cold load before declaring failure.
  local waited=0
  until curl -sf -m 5 "$TARGET/v1/models" >/dev/null 2>&1; do
    sleep 10; waited=$((waited + 10))
    if [ "$waited" -ge "${READY_TIMEOUT:-900}" ]; then
      log "$slug: never ready after ${waited}s"; RESULT[$slug]="na|serve_fail|not ready"; return
    fi
  done
  log "$slug: ready after ${waited}s"

  if [ "${SKIP_SMOKE:-0}" != 1 ] && [ -f "$STUB" ]; then
    scripts/smoke.sh "$STUB" >&2 || { log "$slug: SMOKE FAIL"; RESULT[$slug]="na|smoke_fail|gate 1"; return; }
  fi

  local exp_id; exp_id="$(date -u +%Y%m%d-%H%M%S)"
  local i
  for i in $(seq 1 "$N"); do
    log "$slug: bench $i/$N"
    TAG="$slug" NOTES="exp=$exp_id n$i" scripts/bench_ds4.sh chat >&2 || { log "$slug: bench $i failed"; break; }
  done

  local c1; c1="$(python3 - "$RESDIR/results.tsv" "$exp_id" <<'PY'
import sys, csv, statistics
tsv, exp = sys.argv[1:3]
v = []
try: rows = list(csv.DictReader(open(tsv), delimiter='\t'))
except FileNotFoundError: rows = []
for r in rows:
    if exp in (r.get('notes') or ''):
        try: v.append(float(r['tps_c1']))
        except (ValueError, TypeError): pass
print(round(statistics.median(v), 2) if v else 'na')
PY
)"
  local note
  if [ "$c1" != na ]; then
    if awk "BEGIN{exit !($c1 > $BASE_C1*1.03)}"; then
      note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c1/$BASE_C1-1)*100}")%) — NEEDS ITS OWN GATE 2 (DSpark is not greedy-lossless)"
    else
      note="discard ($(awk "BEGIN{printf \"%+.1f\",($c1/$BASE_C1-1)*100}")%)"
    fi
  else note="discard (no result)"; fi
  RESULT[$slug]="$c1|ok|$note"
  log "$slug -> c1=$c1 :: $note"
}

declare -a QUEUE=(dspark-default dspark-c05 dspark-c085 dspark-strict)
want(){ local s="$1"; shift; [ "$#" -eq 0 ] && return 0; for a in "$@"; do [ "$a" = "$s" ] && return 0; done; return 1; }
SEL=("$@")

log "=== ds4 round 4 start (target-only base c1=$BASE_C1, engine $(git -C "$HOME/code/ds4" rev-parse --short HEAD)) ==="

# The headline re-test: DSpark at the engine default, now with the verifier-state commit.
want dspark-default "${SEL[@]}" && run dspark-default "DSpark @ CUDA default confidence 0.7" DSPARK=1
# The new axis. Lower = admit more draft suffixes; higher = prune harder.
want dspark-c05  "${SEL[@]}" && run dspark-c05  "DSpark confidence 0.5 (admit more drafts)"  DSPARK=1 DSPARK_CONF=0.5
want dspark-c085 "${SEL[@]}" && run dspark-c085 "DSpark confidence 0.85 (prune harder)"      DSPARK=1 DSPARK_CONF=0.85
# Control: loads DSpark but keeps target-only decode. Isolates load-time/verifier overhead from
# the speculative win, and is the byte-for-byte reproducibility leg.
want dspark-strict "${SEL[@]}" && run dspark-strict "DSpark loaded, target-only decode (control)" DSPARK=1 DSPARK_STRICT=1

{
  echo
  echo "## DS4 round 4 — DSpark re-test ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Engine \`ds4@$(git -C "$HOME/code/ds4" rev-parse --short HEAD)\`; target-only base c1 **$BASE_C1** (same session)."
  echo "Objective c1, N=$N median, greedy. KEEP rule: c1 > +3%."
  echo
  echo "| candidate | hypothesis | c1 | status | verdict |"
  echo "|---|---|---|---|---|"
  for slug in "${QUEUE[@]}"; do
    want "$slug" "${SEL[@]}" || continue
    IFS='|' read -r c1 st nt <<<"${RESULT[$slug]:-na|na|not run}"
    echo "| $slug | ${HYP[$slug]:-} | $c1 | $st | $nt |"
  done
} >> "$SUM"

log "=== round 4 DONE ==="
sed -n '/## DS4 round 4/,$p' "$SUM"
