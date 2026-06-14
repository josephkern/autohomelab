#!/usr/bin/env bash
# Tune queue — vLLM 0.23.0, RedHatAI/gemma-4-31B-it-NVFP4 (DENSE NVFP4, bandwidth-bound, KV-limited).
# ABLATION: each candidate = the 0.23.0 baseline + ONE change, N=3 (c1 sentinel + c16 objective)
# vs the same baseline. Variants pre-generated on disk (committed). Smoke-gated per run.
# Quality gate uses gsm8k (generative; baseline 73.0) — NOT standard mmlu (loglikelihood artifact=41
# on this arch). To bound cost (gemma evals are slow), a numeric-risky candidate is quality-evaled
# ONLY IF it first WINS on throughput. Full gsm8k+mmlu_pro recovery is re-checked at finalize.
# Does NOT auto-promote — writes a report with the recommendation.
set -uo pipefail
cd "$(dirname "$0")/.."
RBDIR=runbooks/RedHatAI/gemma-4-31B-it-NVFP4
BASE="$RBDIR/baseline.sh"
RESDIR=results/gb10-1988a9714b4e/RedHatAI/gemma-4-31B-it-NVFP4
SUM="$RESDIR/OVERNIGHT-gemma-0.23.0.md"
GSM_REF=73.0   # baseline gsm8k (LIMIT=100) — relative quality reference for numeric-risky knobs
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

measure(){ N=3 scripts/run_experiment.sh "$1" 2>&1 | grep '^MEDIAN' | tail -1; }

# slug | quality_risky(1)
CANDIDATES=( "kvfp8|1" "memutil-08|0" "batched-16k|0" "linear-marlin|1" "linear-b12x|1" )
declare -A RESULT

log "=== gemma tune queue start (vLLM 0.23.0) ==="
log "measuring 0.23.0 baseline (N=3, c1/c16)"
BL=$(measure "$BASE"); BASE_C16=$(parse c16 "$BL"); log "baseline: $BL"
[ -z "${BASE_C16:-}" ] || [ "$BASE_C16" = na ] && BASE_C16=109

run_candidate(){
  local slug="$1" risky="$2"
  local rb="$RBDIR/20260614_${slug}_tuned.sh"
  [ -f "$rb" ] || { log "MISSING $rb"; RESULT[$slug]="na|na|missing|absent"; return; }
  log "--- candidate: $slug ($(sed -n 's/^# Deltas vs base: //p' "$rb")) ---"
  git add "$rb" 2>/dev/null && git commit -q -m "exp(gemma/0.23.0): $slug" 2>/dev/null
  local m c16 c1 st; m=$(measure "$rb"); c16=$(parse c16 "$m"); c1=$(parse c1 "$m"); st=$(parse status "$m")
  log "$slug -> $m"
  local won=0 note="vs base ${BASE_C16}"
  if [ "$st" = ok ] && [ -n "$c16" ] && [ "$c16" != na ]; then
    if awk "BEGIN{exit !($c16 > $BASE_C16*1.03)}"; then
      won=1; note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c16/$BASE_C16-1)*100}")% c16)"
    else
      note="discard ($(awk "BEGIN{printf \"%+.1f\",($c16/$BASE_C16-1)*100}")%, within noise)"
    fi
  else note="discard ($st)"; fi
  # numeric-risky AND won on throughput -> quality eval (gsm8k, matched LIMIT=100)
  if [ "$risky" = 1 ] && [ "$won" = 1 ]; then
    log "$slug won + numeric-risky -> gsm8k eval (LIMIT=100)"
    if scripts/serve.sh "$rb" >/tmp/qg_serve.log 2>&1; then
      TASKS=gsm8k LIMIT=100 scripts/eval.sh "$rb" general >/tmp/qg_eval.log 2>&1 || log "eval err"
      scripts/serve.sh down >/dev/null 2>&1
      local ch sc gsm; ch="$(sha256sum "$rb"|cut -c1-8)"
      sc=$(tail -n +2 "$RESDIR/accuracy.tsv" | awk -F'\t' -v c="$ch" '$5==c{print $10}' | tail -1)
      gsm=$(sed -n 's/.*gsm8k=\([0-9.]*\).*/\1/p' <<<"$sc")
      if [ -n "$gsm" ]; then
        note="$note; gsm8k=$gsm ($(awk "BEGIN{printf \"%+.1f\",($gsm/$GSM_REF-1)*100}")% vs $GSM_REF)"
        awk "BEGIN{exit !($gsm < $GSM_REF*0.98)}" && note="$note [QUALITY FAIL >2% drop]"
      else note="$note; gsm8k=na"; fi
    else note="$note; eval-serve-fail"; fi
  fi
  RESULT[$slug]="${c16:-na}|${c1:-na}|${st:-na}|$note"
}

for e in "${CANDIDATES[@]}"; do IFS='|' read -r slug risky <<<"$e"; run_candidate "$slug" "$risky"; done

{
  echo "# gemma-4-31B tune queue — vLLM 0.23.0 ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Baseline (dense NVFP4, auto cutlass GEMM, kv auto) median **c16 = ${BASE_C16}** tok/s (N=3)."
  echo "Keep threshold c16 > +3%. Quality (gsm8k) ref = ${GSM_REF}; numeric-risky winners must stay >-2%."
  echo
  echo "| candidate | c16 | c1 | status | verdict |"
  echo "|---|---|---|---|---|"
  for e in "${CANDIDATES[@]}"; do IFS='|' read -r slug _ <<<"$e"
    IFS='|' read -r c16 c1 st nt <<<"${RESULT[$slug]:-na|na|na|not run}"
    echo "| $slug | $c16 | $c1 | $st | $nt |"
  done
  echo
  echo "Recommendation: promote the best KEEP that passes quality via FULL=1 scripts/suite.sh +"
  echo "scripts/promote.sh VLLM_TAG=23 -> VLLM-23-RedHatAI_gemma-4-31B-it_NVFP4_final.sh; else baseline stands."
} > "$SUM"
git add -A && git commit -q -m "gemma tune queue: ablation results + report" 2>/dev/null
log "=== gemma tune queue DONE — report: $SUM ==="
cat "$SUM"
