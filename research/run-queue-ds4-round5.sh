#!/usr/bin/env bash
# DS4 round 5 — the DSpark adaptive SCHEDULER (20260810). Engine ds4@84cc882, DSpark promoted.
#
# WHY: `DS4_DSPARK_STATS=1` on the promoted config showed the scheduler declining to draft in
# **89 of 152 cycles (59%)**, with 112 cycles (74%) producing no draft at all — while acceptance
# WHEN it drafts is 72.84%. DSpark earns its +7.0% while speculating in ~a quarter of cycles. If
# those break-even heuristics are calibrated for other hardware, forcing more drafting is where the
# remaining headroom is. Measurement-backed, not a guess.
#
# NOT --mtp-margin: that is unreachable under DSpark (ds4_session_eval_speculative_argmax() returns
# into the DSpark path at ds4.c:~66049 before e->mtp_margin is read at :66091, and it is further
# gated on the legacy draft_n==2). Retracted in the logbook.
#
# These knobs are ENV, not flags — nohup inherits them, and the launcher logs them since
# bench_ds4.sh's config_hash (built from the cmdline) CANNOT distinguish env-tuned runs.
# DS4_DSPARK_STATS=1 is set on every leg so each teardown flushes its own stats block to the log
# (they print from ds4_session_free()).
#
#   BASE_C1=<this-session DSpark-default median> research/run-queue-ds4-round5.sh [slug ...]
set -uo pipefail
cd "$(dirname "$0")/.."

LAUNCHER=launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh
STUB=launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.smoke-runbook.sh
RESDIR="results/gb10-1988a9714b4e/antirez/DeepSeek-V4-Flash"
SUM="$RESDIR/ROUND5-dspark-scheduler.md"
DS4LOG="$HOME/.ds4/deepseek-v4-flash.log"
TARGET="http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}"
BASE_C1="${BASE_C1:?set BASE_C1=<this-session DSpark-default median c1>}"
N="${N:-3}"
export LEVELS_SET="${LEVELS_SET:-1}" MAX_SECONDS="${MAX_SECONDS:-180}"

log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
declare -A RESULT HYP STATS

run(){  # run <slug> <hypothesis> <env assignments...>
  local slug="$1" hyp="$2"; shift 2
  log "--- $slug ($hyp) [$*] ---"
  HYP[$slug]="$hyp"

  if ! env DS4_DSPARK_STATS=1 "$@" "$LAUNCHER" >&2; then
    log "$slug: launcher failed"; RESULT[$slug]="na|serve_fail|launcher error"; return
  fi
  local waited=0
  until curl -sf -m 5 "$TARGET/v1/models" >/dev/null 2>&1; do
    sleep 10; waited=$((waited + 10))
    if [ "$waited" -ge "${READY_TIMEOUT:-900}" ]; then
      log "$slug: never ready after ${waited}s"; RESULT[$slug]="na|serve_fail|not ready"; return
    fi
  done
  log "$slug: ready after ${waited}s"

  if [ "${SKIP_SMOKE:-0}" != 1 ]; then
    scripts/smoke.sh "$STUB" >&2 || { log "$slug: SMOKE FAIL"; RESULT[$slug]="na|smoke_fail|gate 1"; return; }
  fi

  local exp_id; exp_id="$(date -u +%Y%m%d-%H%M%S)"
  local i
  for i in $(seq 1 "$N"); do
    log "$slug: bench $i/$N"
    TAG="$slug" NOTES="exp=$exp_id n$i round5 env=[$*]" scripts/bench_ds4.sh chat >&2 \
      || { log "$slug: bench $i failed"; break; }
  done

  # Tear the server down so ds4_session_free() flushes this leg's DSpark stats into the log.
  "$LAUNCHER" stop >/dev/null 2>&1 || true
  sleep 3
  STATS[$slug]="$(grep -i 'DSpark stats' "$DS4LOG" | tail -1 | grep -oP '(cycles|accept_rate|no_draft|scheduler_skips|avg_accept)=\S+' | tr '\n' ' ')"
  log "$slug stats: ${STATS[$slug]:-none}"

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
      note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c1/$BASE_C1-1)*100}")%) — re-confirm at higher N before promoting (DSpark legs run 2-7% spread)"
    else
      note="discard ($(awk "BEGIN{printf \"%+.1f\",($c1/$BASE_C1-1)*100}")%)"
    fi
  else note="discard (no result)"; fi
  RESULT[$slug]="$c1|ok|$note"
  log "$slug -> c1=$c1 :: $note"
}

declare -a QUEUE=(sched-off sched-skip0 sched-nodraft0 sched-window1)
want(){ local s="$1"; shift; [ "$#" -eq 0 ] && return 0; for a in "$@"; do [ "$a" = "$s" ] && return 0; done; return 1; }
SEL=("$@")

log "=== ds4 round 5 start (DSpark-default base c1=$BASE_C1, engine $(git -C "$HOME/code/ds4" rev-parse --short HEAD)) ==="

# The headline: disable the break-even scheduler entirely -> always draft.
want sched-off "${SEL[@]}" && run sched-off "scheduler OFF (always draft)" DS4_DSPARK_SCHEDULER=0
# Softer: keep the scheduler but stop it sitting out cycles after a bad outcome (default 2).
want sched-skip0 "${SEL[@]}" && run sched-skip0 "SCHEDULER_SKIP 2->0 (no cooldown after a miss)" DS4_DSPARK_SCHEDULER_SKIP=0
# no_draft=112 was the largest bucket; this is the cooldown that follows a no-draft cycle (default 3).
want sched-nodraft0 "${SEL[@]}" && run sched-nodraft0 "NO_DRAFT_SKIP 3->0" DS4_DSPARK_SCHEDULER_NO_DRAFT_SKIP=0
# Shorter averaging window (default 4) -> react faster, commit to drafting sooner.
want sched-window1 "${SEL[@]}" && run sched-window1 "SCHEDULER_WINDOW 4->1" DS4_DSPARK_SCHEDULER_WINDOW=1

{
  echo
  echo "## DS4 round 5 — DSpark adaptive scheduler ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Engine \`ds4@$(git -C "$HOME/code/ds4" rev-parse --short HEAD)\`, DSpark on (conf 0.7 default)."
  echo "Same-session DSpark-default base c1 **$BASE_C1**. Objective c1, N=$N median, greedy. KEEP > +3%."
  echo "Motivation: baseline stats showed \`scheduler_skips=89/152 cycles (59%)\`, \`no_draft=112\`,"
  echo "yet \`accept_rate=72.84%\` when it does draft."
  echo
  echo "| candidate | hypothesis | c1 | status | verdict | DSpark stats |"
  echo "|---|---|---|---|---|---|"
  for slug in "${QUEUE[@]}"; do
    want "$slug" "${SEL[@]}" || continue
    IFS='|' read -r c1 st nt <<<"${RESULT[$slug]:-na|na|not run}"
    echo "| $slug | ${HYP[$slug]:-} | $c1 | $st | $nt | \`${STATS[$slug]:-}\` |"
  done
} >> "$SUM"

log "=== round 5 DONE ==="
sed -n '/## DS4 round 5/,$p' "$SUM"
