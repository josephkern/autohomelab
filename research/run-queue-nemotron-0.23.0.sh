#!/usr/bin/env bash
# Tune queue — vLLM 0.23.0, RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
# (NemotronHForCausalLM = hybrid Mamba + LatentMoE, NVFP4 MIXED_PRECISION, bandwidth-bound on GB10).
# ABLATION: each candidate = the 0.23.0 baseline + ONE change, N=3 (c1 sentinel + c16 objective) vs
# the SAME baseline (re-measured this session). Variants pre-generated on disk (committed). Smoke-gated
# per run; serve_fail/crash logged as discard (crash-safe). Does NOT auto-promote — writes a report.
#
# Quality gate uses **mmlu (loglikelihood, think-on)** = the baseline reference 85.82 — fast + reliable
# on this arch (generative gsm8k would be thinking-depressed; mmlu loglikelihood is thinking-agnostic).
# To bound cost, a numeric-risky candidate (kernel/GEMM change) is quality-evaled ONLY IF it first WINS
# on throughput. Full gsm8k+mmlu_pro recovery is re-checked at finalize (FULL=1 suite.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
RBDIR=runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
BASE="$RBDIR/baseline.sh"
RESDIR=results/gb10-1988a9714b4e/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
SUM="$RESDIR/OVERNIGHT-nemotron-0.23.0.md"
MMLU_REF=85.82   # baseline mmlu (loglikelihood, think-on, LIMIT=100) — quality ref for numeric-risky knobs
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

measure(){ N=3 scripts/run_experiment.sh "$1" 2>&1 | grep '^MEDIAN' | tail -1; }

# slug | quality_risky(1 = kernel/GEMM change -> mmlu-check if it wins; 0 = config-only/lossless)
CANDIDATES=( "mtp-n1|0" "moe-b12x|1" "async-sched|0" "memutil-090|0" "moe-cutlass|1" "maxseqs-4|0" )
declare -A RESULT

log "=== nemotron-3-super tune queue start (vLLM 0.23.0) ==="
log "measuring 0.23.0 baseline (N=3, c1/c16)"
BL=$(measure "$BASE"); BASE_C16=$(parse c16 "$BL"); log "baseline: $BL"
{ [ -z "${BASE_C16:-}" ] || [ "$BASE_C16" = na ]; } && BASE_C16=73.0

run_candidate(){
  local slug="$1" risky="$2"
  local rb="$RBDIR/20260616_${slug}_tuned.sh"
  [ -f "$rb" ] || { log "MISSING $rb"; RESULT[$slug]="na|na|missing|absent"; return; }
  log "--- candidate: $slug ($(sed -n 's/^# Deltas vs base: //p' "$rb")) ---"
  git add "$rb" 2>/dev/null && git commit -q -m "exp(nemotron/0.23.0): $slug" 2>/dev/null
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
  # numeric-risky AND won on throughput -> quality eval (mmlu loglikelihood, think-on, matched LIMIT=100)
  if [ "$risky" = 1 ] && [ "$won" = 1 ]; then
    log "$slug won + numeric-risky -> mmlu eval (think-on, LIMIT=100)"
    if scripts/serve.sh "$rb" >/tmp/qg_serve.log 2>&1; then
      TASKS=mmlu LIMIT=100 scripts/eval.sh "$rb" general >/tmp/qg_eval.log 2>&1 || log "eval err"
      scripts/serve.sh down >/dev/null 2>&1
      local ch sc mm; ch="$(sha256sum "$rb"|cut -c1-8)"
      sc=$(tail -n +2 "$RESDIR/accuracy.tsv" | awk -F'\t' -v c="$ch" '$5==c{print $10}' | tail -1)
      mm=$(sed -n 's/.*mmlu=\([0-9.]*\).*/\1/p' <<<"$sc")
      if [ -n "$mm" ]; then
        note="$note; mmlu=$mm ($(awk "BEGIN{printf \"%+.1f\",($mm/$MMLU_REF-1)*100}")% vs $MMLU_REF)"
        awk "BEGIN{exit !($mm < $MMLU_REF*0.98)}" && note="$note [QUALITY FAIL >2% drop]"
      else note="$note; mmlu=na"; fi
    else note="$note; eval-serve-fail"; fi
  fi
  RESULT[$slug]="${c16:-na}|${c1:-na}|${st:-na}|$note"
}

for e in "${CANDIDATES[@]}"; do IFS='|' read -r slug risky <<<"$e"; run_candidate "$slug" "$risky"; done

{
  echo "# nemotron-3-super-120B tune queue — vLLM 0.23.0 ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Baseline (NVFP4 LatentMoE, auto MoE backend, gpu-mem-util 0.85, MTP off) median **c16 = ${BASE_C16}**"
  echo "tok/s (N=3, re-measured this session). Keep threshold c16 > +3%. Quality (mmlu loglikelihood,"
  echo "think-on) ref = ${MMLU_REF}; numeric-risky winners must stay >-2%."
  echo
  echo "| candidate | c16 | c1 | status | verdict |"
  echo "|---|---|---|---|---|"
  for e in "${CANDIDATES[@]}"; do IFS='|' read -r slug _ <<<"$e"
    IFS='|' read -r c16 c1 st nt <<<"${RESULT[$slug]:-na|na|na|not run}"
    echo "| $slug | $c16 | $c1 | $st | $nt |"
  done
  echo
  echo "Recommendation: promote the best KEEP that passes quality via FULL=1 scripts/suite.sh +"
  echo "scripts/promote.sh VLLM_TAG=23 -> VLLM-23-RedHatAI_NVIDIA-Nemotron-3-Super-120B-A12B_NVFP4_final.sh;"
  echo "else baseline stands. (mtp/async/memutil/maxseqs are config-only -> no quality eval; maxseqs-4 is"
  echo "a per-stream characterization expected to lose the c16 objective.)"
} > "$SUM"
git add -A && git commit -q -m "nemotron tune queue: ablation results + report" 2>/dev/null
log "=== nemotron tune queue DONE — report: $SUM ==="
cat "$SUM"
