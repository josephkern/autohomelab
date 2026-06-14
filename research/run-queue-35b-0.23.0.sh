#!/usr/bin/env bash
# Tune queue — vLLM 0.23.0, RedHatAI/Qwen3.6-35B-A3B-NVFP4 (MoE A3B + hybrid attn + MTP).
# ABLATION: each candidate = the 0.23.0 baseline + ONE change, measured (N=3, c1 sentinel +
# c16 objective) vs the same baseline. Variants are pre-generated on disk (research/, committed).
# Smoke-gated per run (run_experiment); numeric-risky knobs (MoE GEMM backend) also get an mmlu
# eval (LIMIT=100, matched to the baseline reference). Does NOT auto-promote — writes a report with
# the recommendation; promotion stays a reviewed step (validate.sh + promote.sh).
set -uo pipefail   # NOT -e: keep going past a failed candidate
cd "$(dirname "$0")/.."
RBDIR=runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4
BASE="$RBDIR/baseline.sh"
RESDIR=results/gb10-1988a9714b4e/RedHatAI/Qwen3.6-35B-A3B-NVFP4
SUM="$RESDIR/OVERNIGHT-35b-0.23.0.md"
MMLU_REF=78.19   # baseline mmlu (LIMIT=100) — quality reference for numeric-risky knobs
export LEVELS_SET=1,16 MAX_SECONDS=180 N=3 EXP_SHAPE=chat
log(){ echo "[$(date -u +%H:%M:%S)] $*"; }
parse(){ sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }   # parse <key> <medianline>

measure(){ N=3 scripts/run_experiment.sh "$1" 2>&1 | grep '^MEDIAN' | tail -1; }

# candidate registry: slug | quality_risky(1=eval mmlu)
CANDIDATES=(
  "moe-auto|1"
  "moe-marlin|1"
  "mtp-off|0"
  "mtp-n2|0"
  "memutil-08|0"
  "batched-32k-util08|0"
)
declare -A RESULT   # slug -> "c16|c1|status|note"

log "=== 35B tune queue start (vLLM 0.23.0) ==="
log "measuring 0.23.0 baseline (N=3, c1/c16)"
BL=$(measure "$BASE"); BASE_C16=$(parse c16 "$BL"); log "baseline: $BL"
[ -z "${BASE_C16:-}" ] && BASE_C16=340.58   # fall back to the recorded baseline c16

run_candidate(){
  local slug="$1" risky="$2"
  local rb="$RBDIR/20260614_${slug}_tuned.sh"
  [ -f "$rb" ] || { log "MISSING variant $rb — skip"; RESULT[$slug]="na|na|missing|variant file absent"; return; }
  log "--- candidate: $slug ($(sed -n 's/^# Deltas vs base: //p' "$rb")) ---"
  git add "$rb" 2>/dev/null && git commit -q -m "exp(35b/0.23.0): $slug" 2>/dev/null
  local m c16 c1 st; m=$(measure "$rb"); c16=$(parse c16 "$m"); c1=$(parse c1 "$m"); st=$(parse status "$m")
  log "$slug -> $m"
  local note="vs base ${BASE_C16}"
  if [ "$st" = ok ] && [ -n "$c16" ] && [ "$c16" != na ]; then
    if awk "BEGIN{exit !($c16 > $BASE_C16*1.03)}"; then
      note="KEEP (+$(awk "BEGIN{printf \"%.1f\",($c16/$BASE_C16-1)*100}")% c16)"
    else
      note="discard (within noise: $(awk "BEGIN{printf \"%+.1f\",($c16/$BASE_C16-1)*100}")%)"
    fi
  else note="discard ($st)"; fi
  # numeric-risky (MoE GEMM backend): if it served, eval mmlu at the matched LIMIT and compare recovery
  if [ "$risky" = 1 ] && [ "$st" = ok ]; then
    log "$slug numeric-risky -> mmlu eval (LIMIT=100)"
    if scripts/serve.sh "$rb" >/tmp/q35_serve.log 2>&1; then
      TASKS=mmlu LIMIT=100 scripts/eval.sh "$rb" general >/tmp/q35_eval.log 2>&1 || log "eval errored (see /tmp/q35_eval.log)"
      scripts/serve.sh down >/dev/null 2>&1
      local ch sc; ch="$(sha256sum "$rb"|cut -c1-8)"
      sc=$(tail -n +2 "$RESDIR/accuracy.tsv" | awk -F'\t' -v c="$ch" '$5==c{print $10}' | tail -1)
      local mmlu; mmlu=$(sed -n 's/.*mmlu=\([0-9.]*\).*/\1/p' <<<"$sc")
      if [ -n "$mmlu" ]; then
        local rec; rec=$(awk "BEGIN{printf \"%.1f\",($mmlu/$MMLU_REF-1)*100}")
        note="$note; mmlu=$mmlu (${rec}% vs ref $MMLU_REF)"
        awk "BEGIN{exit !($mmlu < $MMLU_REF*0.99)}" && note="$note [QUALITY FAIL >1% drop]"
      else note="$note; mmlu=na"; fi
    else note="$note; eval-serve-fail"; fi
  fi
  RESULT[$slug]="${c16:-na}|${c1:-na}|${st:-na}|$note"
}

for entry in "${CANDIDATES[@]}"; do
  IFS='|' read -r slug risky <<<"$entry"
  run_candidate "$slug" "$risky"
done

# Report
{
  echo "# 35B tune queue — vLLM 0.23.0, Qwen3.6-35B-A3B-NVFP4 ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "Baseline (0.23.0, flashinfer_cutlass MoE + fp8 KV + MTP n=1) median **c16 = ${BASE_C16}** tok/s"
  echo "(N=3). Keep threshold: c16 > +3%. Quality ref: mmlu=${MMLU_REF} (LIMIT=100); numeric-risky"
  echo "knobs must stay within ~1%."
  echo
  echo "| candidate | c16 | c1 | status | verdict |"
  echo "|---|---|---|---|---|"
  for entry in "${CANDIDATES[@]}"; do
    IFS='|' read -r slug _ <<<"$entry"
    IFS='|' read -r c16 c1 st nt <<<"${RESULT[$slug]:-na|na|na|not run}"
    echo "| $slug | $c16 | $c1 | $st | $nt |"
  done
  echo
  echo "Recommendation: promote the best KEEP that also passes quality (if numeric-risky) via"
  echo "scripts/validate.sh + scripts/promote.sh -> VLLM-23-RedHatAI_Qwen3.6-35B-A3B_NVFP4_final.sh;"
  echo "else the migrated baseline stands. Independent wins can be combined into one variant + re-validated."
} > "$SUM"
git add -A && git commit -q -m "35b tune queue: ablation results + report" 2>/dev/null
log "=== 35B tune queue DONE — report: $SUM ==="
cat "$SUM"
